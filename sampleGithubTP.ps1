# Sample code from the web
# http://mvalipour.github.io/devops/2016/08/10/generate-releasenotes-github-targetprocess

Param(
  [Parameter(Mandatory=$true)][string]$git_url,
  [Parameter(Mandatory=$true)][string]$github_token,
  [string]$github_base = "master",
  [string]$github_head = "develop",
  [string]$version_build = "0",
  [Parameter(Mandatory=$true)][string]$tp_domain,
  [Parameter(Mandatory=$true)][string]$tp_username,
  [Parameter(Mandatory=$true)][string]$tp_password
)

# consts
$regex_git_url = "https?:\/\/github.com\/(?<owner>[\w\.]+)\/(?<repo>[\w\.]+)\.git"
$regex_pr_commit = "Merge pull request #(?<number>\d+)"
$regex_tp_entity = "https://$tp_domain.tpondemand.com/entity/(?<number>\d+)"

# prep
$git_url -match $regex_git_url | Out-Null
$github_owner = $Matches.owner
$github_repo = $Matches.repo
$version_number = (Get-Content .\.version).Trim()

Write-Host "Using github owner... $github_owner"
Write-Host "Using github repo... $github_repo"
Write-Host "Using version number... $version_number"

#
# GitHub
# ---------------------------------------------------------

function Request-GitHub($path) {
    $headers = @{ "Authorization" = "token $github_token" }
    return Invoke-RestMethod -Uri "https://api.github.com$path" -Headers $headers
}

function Get-GitHubCommits($base, $head)
{
    return Request-GitHub "/repos/$github_owner/$github_repo/compare/$base...$head"
}

function Get-GitHubPRs($term) {
    return Request-GitHub "/search/issues?q=is:pr+repo:$github_owner/$github_repo+$term"
}

#
# Target process
# ---------------------------------------------------------
function Request-TargetProcess($path) {
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($tp_username):$($tp_password)"))
    $headers = @{ "Authorization" = "Basic $base64AuthInfo"; "Accept" = "application/json" }
    try {
        return Invoke-RestMethod -Uri "http://$tp_domain.tpondemand.com/api/v1$path" -Headers $headers
    }
    catch { return $null }
}

function Get-TargetProcessEntity($col, $id) {
    return Request-TargetProcess "/$col/$id"
}

function BatchGet-TargetProcessEntities($ids)
{
    return $ids | ForEach-Object {
        $res = New-Object -TypeName psobject -Property @{ Id = $_ };
	    $getters = @(
		    @{ Collection = "UserStories"; Type = "UserStory" },
		    @{ Collection = "Bugs"; Type = "Bug" },
		    @{ Collection = "Features"; Type = "Feature" }
	    )

	    foreach($g in $getters) {
		    $e = Get-TargetProcessEntity $g.Collection $_
		    if(-not $e) { continue }
            if($ids -contains $e.UserStory.Id -or $ids -contains $e.Feature.Id) {
                Write-Host "Found $($e.ResourceType) with Id=$($e.Id) BUT it's parent is already in the list."
                return $null
            }

            Write-Host "Found $($e.ResourceType) with Id=$($e.Id)"
            return $e
	    }
        Write-Host "Could not find target process entity with id=$($res.Id)"
        return $res
    }
}

#
# Main
# ---------------------------------------------------------
function List-PullRequests()
{
    return (Get-GitHubCommits $github_base  $github_head).commits | Sort-Object -Property @{Expression={$_.commit.author.date}; Ascending=$false} -Descending | Where-Object {
        $_.commit.message -match $regex_pr_commit
    } | ForEach-Object {
        $_.commit.message -match $regex_pr_commit | Out-Null
        return $Matches.number
    }
}

function Retrieve-TargetProcessEntities($nums)
{
    # slice into chunks -- becaues of github search length limit
    $numlists = @()
    $nums | ForEach-Object {
        $li = $numlists.Length - 1
        $l = $numlists[$li]
        if($l -eq $null-or $l.Length -gt 200) { $numlists += $_ }
        else { $numlists[$li] += "+$_" }
    }

    # search github for each batch
    return $numlists | % {
        Write-Host "Fetching PRs batch..."
        return (Get-GitHubPRs $_).items | select number, body
    } | Where-Object {
        # Make sure there are no false positives by checking PR number is present in the original list
        $nums -contains $_.number
    } | % {
        $_.body | Select-String -Pattern $regex_tp_entity -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value }
    } | Sort-Object { $_ } | select -Unique
}

function Generate-Notes($tp_entities)
{
    $groups = $tp_entities | Group-Object -Property ResourceType
    $out = "## Release Notes - $version_number (build #$version_build)

"
    if($groups.Count -lt 1)
    {
        $out += "Well... nothing really."
        return $out
    }

    foreach($g in $groups)
    {
        $gStr = $g.Group | % { "- #$($_.Id): $(if(-not $_.Name){ "Unknown" } else { $_.Name })" } | Out-String
        $out += "### $(if(-not $g.Name){ "Unknown" } else { $g.Name })

$gStr
"
    }

    return $out
}

function Main()
{
    Write-Host "Reading PRs from GitHub..."
    $pr_list = List-PullRequests
    Write-Host "$($pr_list.Count) PRs found."

    Write-Host "Retrieving Target-Process entities from GitHub..."
    $tp_entity_ids = Retrieve-TargetProcessEntities $pr_list
    Write-Host "$($tp_entity_ids.Count) TP Entities found."

    Write-Host "Fetching Target-Process entities"
    $tp_entities = BatchGet-TargetProcessEntities $tp_entity_ids | ? { $_ }

    Write-host "Generating notes..."
    $releaseNotes = Generate-Notes $tp_entities

    Write-host "Writing output... Length=$($releaseNotes.Length)"
    $releaseNotesPath = "$((Get-Item -Path ".\").FullName)\bin\artefacts\release-notes.txt"
    New-Item -Force -Path $releaseNotesPath -ItemType File -Value $releaseNotes | Out-Null
    Write-Host "Output was witten to: $releaseNotesPath"

    Write-Host "Writing release notes json file"
    $releaseNotesInfo = @{
        Version = $version_number
        BuildNumber = $version_build
        PullRequests = $pr_list
        TargetProcessEntities = ($tp_entities | select Id, Name, ResourceType)
    }
    $targetProcessIdsPath = "$((Get-Item -Path ".\").FullName)\bin\artefacts\release-info.json"
    $releaseNotesInfo | ConvertTo-Json | Out-File -Force -FilePath $targetProcessIdsPath
    Write-Host "Output was witten to: $targetProcessIdsPath"

    # set teamcity variable
    if(Test-Path env:\TEAMCITY_VERSION)
    {
        Write-Host "##teamcity[setParameter name='releaseNotesPath' value='$releaseNotesPath']"
    }
}

Main

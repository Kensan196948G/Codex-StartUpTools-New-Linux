Set-StrictMode -Version Latest

$script:DefaultStatePath = "state.json"
$script:MaxMessagesPerTopic = 10
$script:AllowedTopics = @(
    "phase.transition",
    "ci.status"
)

function Get-StateFilePath {
    param([string]$RepoRoot)

    if (-not $RepoRoot) {
        $root = git rev-parse --show-toplevel 2>$null
        $RepoRoot = if ($root) { $root } else { "." }
    }

    return Join-Path $RepoRoot $script:DefaultStatePath
}

function Read-StateJson {
    param([string]$StatePath)

    if (-not (Test-Path $StatePath)) {
        throw "state.json が見つかりません: $StatePath"
    }

    $raw = Get-Content -Path $StatePath -Raw -Encoding UTF8
    return $raw | ConvertFrom-Json
}

function Write-StateJson {
    param(
        [string]$StatePath,
        [psobject]$State
    )

    $json = $State | ConvertTo-Json -Depth 10 -Compress:$false
    Set-Content -Path $StatePath -Value $json -Encoding UTF8 -NoNewline
}

function New-BusSection {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Returns in-memory object only.")]
    param()

    $bus = [ordered]@{}
    foreach ($topic in $script:AllowedTopics) {
        $bus[$topic] = @()
    }

    return [pscustomobject]$bus
}

function Assert-TopicAllowed {
    param([string]$Topic)

    if ($Topic -notin $script:AllowedTopics) {
        throw "未対応トピック '$Topic'。Phase 1 で利用可能なトピック: $($script:AllowedTopics -join ', ')"
    }
}

function New-MessageId {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Returns in-memory identifier only.")]
    param()

    $timestamp = Get-Date -Format "yyyyMMddHHmmss"
    $random = -join ((65..90) + (97..122) | Get-Random -Count 4 | ForEach-Object { [char]$_ })
    return "msg-$timestamp-$random"
}

function Publish-BusMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Topic,

        [Parameter(Mandatory = $true)]
        [string]$Publisher,

        [Parameter(Mandatory = $true)]
        [psobject]$Payload,

        [string]$StatePath
    )

    Assert-TopicAllowed -Topic $Topic

    if (-not $StatePath) {
        $StatePath = Get-StateFilePath
    }

    $state = Read-StateJson -StatePath $StatePath
    if (-not ($state.PSObject.Properties.Name -contains "message_bus") -or $null -eq $state.message_bus) {
        $state | Add-Member -MemberType NoteProperty -Name "message_bus" -Value (New-BusSection) -Force
    }

    $bus = $state.message_bus
    if (-not ($bus.PSObject.Properties.Name -contains $Topic)) {
        $bus | Add-Member -MemberType NoteProperty -Name $Topic -Value @() -Force
    }

    $messageId = New-MessageId
    $newMessage = [pscustomobject]@{
        id          = $messageId
        timestamp   = (Get-Date -Format "o")
        publisher   = $Publisher
        payload     = $Payload
        consumed_by = @()
    }

    $queue = @($bus.$Topic)
    $queue += $newMessage
    if ($queue.Count -gt $script:MaxMessagesPerTopic) {
        $queue = $queue | Select-Object -Last $script:MaxMessagesPerTopic
    }

    $bus | Add-Member -MemberType NoteProperty -Name $Topic -Value $queue -Force
    Write-StateJson -StatePath $StatePath -State $state

    Write-Verbose "MessageBus: Published [$Topic] id=$messageId publisher=$Publisher"
    return $messageId
}

function Get-BusMessage {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Topic,

        [string]$Consumer,
        [string]$StatePath
    )

    Assert-TopicAllowed -Topic $Topic

    if (-not $StatePath) {
        $StatePath = Get-StateFilePath
    }

    if (-not (Test-Path $StatePath)) {
        return @()
    }

    $state = Read-StateJson -StatePath $StatePath
    if (-not ($state.PSObject.Properties.Name -contains "message_bus") -or $null -eq $state.message_bus) {
        return @()
    }

    $bus = $state.message_bus
    if (-not ($bus.PSObject.Properties.Name -contains $Topic)) {
        return @()
    }

    $messages = @($bus.$Topic)
    if ($Consumer) {
        $messages = $messages | Where-Object {
            $consumed = @($_.consumed_by)
            $Consumer -notin $consumed
        }
    }

    return $messages
}

function Confirm-BusMessage {
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Topic,

        [Parameter(Mandatory = $true)]
        [string]$MessageId,

        [Parameter(Mandatory = $true)]
        [string]$Consumer,

        [string]$StatePath
    )

    Assert-TopicAllowed -Topic $Topic

    if (-not $StatePath) {
        $StatePath = Get-StateFilePath
    }

    $state = Read-StateJson -StatePath $StatePath
    if (-not ($state.PSObject.Properties.Name -contains "message_bus") -or $null -eq $state.message_bus) {
        return $false
    }

    $bus = $state.message_bus
    if (-not ($bus.PSObject.Properties.Name -contains $Topic)) {
        return $false
    }

    if (-not ($bus.$Topic | Where-Object { $_.id -eq $MessageId })) {
        Write-Verbose "MessageBus: Message '$MessageId' not found in topic '$Topic'"
        return $false
    }

    $updatedQueue = @($bus.$Topic) | ForEach-Object {
        if ($_.id -eq $MessageId) {
            $consumed = @($_.consumed_by)
            if ($Consumer -notin $consumed) {
                $consumed += $Consumer
                $_ | Add-Member -MemberType NoteProperty -Name "consumed_by" -Value $consumed -Force
            }
        }
        $_
    }

    $bus | Add-Member -MemberType NoteProperty -Name $Topic -Value $updatedQueue -Force
    Write-StateJson -StatePath $StatePath -State $state

    Write-Verbose "MessageBus: Confirmed [$Topic] id=$MessageId consumer=$Consumer"
    return $true
}

function Get-BusStatus {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param([string]$StatePath)

    if (-not $StatePath) {
        $StatePath = Get-StateFilePath
    }

    if (-not (Test-Path $StatePath)) {
        Write-Warning "state.json が見つかりません: $StatePath"
        return @()
    }

    $state = Read-StateJson -StatePath $StatePath
    $results = foreach ($topic in $script:AllowedTopics) {
        $count = 0
        $consumed = 0

        if (($state.PSObject.Properties.Name -contains "message_bus") -and
            $null -ne $state.message_bus -and
            ($state.message_bus.PSObject.Properties.Name -contains $topic)) {
            $messages = @($state.message_bus.$topic)
            $count = $messages.Count
            $consumed = @($messages | Where-Object { @($_.consumed_by).Count -gt 0 }).Count
        }

        [pscustomobject]@{
            Topic         = $topic
            TotalMessages = $count
            ConsumedCount = $consumed
            PendingCount  = $count - $consumed
        }
    }

    return $results
}

function Initialize-MessageBus {
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param([string]$StatePath)

    if (-not $StatePath) {
        $StatePath = Get-StateFilePath
    }

    $state = Read-StateJson -StatePath $StatePath
    if (($state.PSObject.Properties.Name -contains "message_bus") -and $null -ne $state.message_bus) {
        Write-Verbose "MessageBus: message_bus セクションは既に存在します (skip)"
        return $false
    }

    $state | Add-Member -MemberType NoteProperty -Name "message_bus" -Value (New-BusSection) -Force
    Write-StateJson -StatePath $StatePath -State $state

    Write-Verbose "MessageBus: message_bus セクションを初期化しました"
    return $true
}

Export-ModuleMember -Function @(
    "Publish-BusMessage",
    "Get-BusMessage",
    "Confirm-BusMessage",
    "Get-BusStatus",
    "Initialize-MessageBus"
)

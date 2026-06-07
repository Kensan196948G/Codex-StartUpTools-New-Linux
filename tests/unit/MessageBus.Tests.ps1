BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/MessageBus.psm1") -Force

    function script:New-TestStateJson {
        param([string]$Path, [hashtable]$ExtraProps = @{})

        $state = [ordered]@{
            goal      = @{ title = "Test" }
            execution = @{ phase = "Monitor" }
        }

        foreach ($key in $ExtraProps.Keys) {
            $state[$key] = $ExtraProps[$key]
        }

        $json = $state | ConvertTo-Json -Depth 10
        Set-Content -Path $Path -Value $json -Encoding UTF8
    }
}

Describe "Initialize-MessageBus" {
    BeforeEach {
        $script:StatePath = Join-Path $TestDrive "state.json"
        New-TestStateJson -Path $script:StatePath
    }

    It "message_bus セクションを追加して true を返す" {
        Initialize-MessageBus -StatePath $script:StatePath | Should -BeTrue
    }

    It "topic を空配列で初期化する" {
        Initialize-MessageBus -StatePath $script:StatePath | Out-Null
        $state = Get-Content $script:StatePath -Raw | ConvertFrom-Json
        @($state.message_bus."phase.transition").Count | Should -Be 0
        @($state.message_bus."ci.status").Count | Should -Be 0
    }
}

Describe "Publish-BusMessage" {
    BeforeEach {
        $script:StatePath = Join-Path $TestDrive "state.json"
        New-TestStateJson -Path $script:StatePath
        Initialize-MessageBus -StatePath $script:StatePath | Out-Null
    }

    It "メッセージ ID を返す" {
        $id = Publish-BusMessage -Topic "phase.transition" -Publisher "Orchestrator" -Payload @{ from = "Monitor"; to = "Development" } -StatePath $script:StatePath
        $id | Should -Match "^msg-"
    }

    It "state.json にメッセージを保存する" {
        Publish-BusMessage -Topic "ci.status" -Publisher "DevOps" -Payload @{ status = "pass" } -StatePath $script:StatePath | Out-Null
        $state = Get-Content $script:StatePath -Raw | ConvertFrom-Json
        @($state.message_bus."ci.status").Count | Should -Be 1
    }

    It "11 件 publish すると最新 10 件だけ保持する" {
        for ($i = 1; $i -le 11; $i++) {
            Publish-BusMessage -Topic "phase.transition" -Publisher "Orchestrator" -Payload @{ seq = $i } -StatePath $script:StatePath | Out-Null
        }

        $state = Get-Content $script:StatePath -Raw | ConvertFrom-Json
        @($state.message_bus."phase.transition").Count | Should -Be 10
        @($state.message_bus."phase.transition")[0].payload.seq | Should -Be 2
    }
}

Describe "Get-BusMessage and Confirm-BusMessage" {
    BeforeEach {
        $script:StatePath = Join-Path $TestDrive "state.json"
        New-TestStateJson -Path $script:StatePath
        Initialize-MessageBus -StatePath $script:StatePath | Out-Null
    }

    It "未読メッセージを取得できる" {
        Publish-BusMessage -Topic "ci.status" -Publisher "DevOps" -Payload @{ status = "pass" } -StatePath $script:StatePath | Out-Null
        @(Get-BusMessage -Topic "ci.status" -Consumer "Orchestrator" -StatePath $script:StatePath).Count | Should -Be 1
    }

    It "Confirm 後は同じ Consumer には返さない" {
        $id = Publish-BusMessage -Topic "ci.status" -Publisher "DevOps" -Payload @{ status = "pass" } -StatePath $script:StatePath
        Confirm-BusMessage -Topic "ci.status" -MessageId $id -Consumer "Orchestrator" -StatePath $script:StatePath | Out-Null
        @(Get-BusMessage -Topic "ci.status" -Consumer "Orchestrator" -StatePath $script:StatePath).Count | Should -Be 0
    }

    It "存在しないメッセージ ID なら false を返す" {
        Confirm-BusMessage -Topic "phase.transition" -MessageId "msg-none" -Consumer "Developer" -StatePath $script:StatePath | Should -BeFalse
    }
}

Describe "Get-BusStatus" {
    BeforeEach {
        $script:StatePath = Join-Path $TestDrive "state.json"
        New-TestStateJson -Path $script:StatePath
        Initialize-MessageBus -StatePath $script:StatePath | Out-Null
    }

    It "2 topic 分のサマリーを返す" {
        @(Get-BusStatus -StatePath $script:StatePath).Count | Should -Be 2
    }

    It "PendingCount を計算できる" {
        $id = Publish-BusMessage -Topic "ci.status" -Publisher "DevOps" -Payload @{ status = "pass" } -StatePath $script:StatePath
        Publish-BusMessage -Topic "ci.status" -Publisher "DevOps" -Payload @{ status = "fail" } -StatePath $script:StatePath | Out-Null
        Confirm-BusMessage -Topic "ci.status" -MessageId $id -Consumer "Orchestrator" -StatePath $script:StatePath | Out-Null

        $row = Get-BusStatus -StatePath $script:StatePath | Where-Object { $_.Topic -eq "ci.status" }
        $row.TotalMessages | Should -Be 2
        $row.ConsumedCount | Should -Be 1
        $row.PendingCount | Should -Be 1
    }
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/TokenBudget.psm1") -Force
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/MessageBus.psm1") -Force

    $script:SchemaPath = Join-Path $script:RepoRoot "state.schema.json"
    $script:ExamplePath = Join-Path $script:RepoRoot "state.json.example"
}

Describe "state artifacts" {
    It "state.schema.json を JSON として読める" {
        { Get-Content -Path $script:SchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json } | Should -Not -Throw
    }

    It "state.json.example を JSON として読める" {
        { Get-Content -Path $script:ExamplePath -Raw -Encoding UTF8 | ConvertFrom-Json } | Should -Not -Throw
    }

    It "スキーマに最小必須キーを定義している" {
        $schema = Get-Content -Path $script:SchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        @($schema.required) | Should -Be @("goal", "execution", "token", "message_bus")
    }
}

Describe "state example structure" {
    BeforeAll {
        $script:ExampleState = Get-Content -Path $script:ExamplePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    It "TokenBudget 互換の token セクションを持つ" {
        $script:ExampleState.token.total_budget | Should -Be 100
        $script:ExampleState.token.allocation.monitor | Should -Be 10
        $script:ExampleState.token.allocation.development | Should -Be 35
        $script:ExampleState.token.dynamic_mode | Should -BeTrue
    }

    It "MessageBus 互換の topic 配列を持つ" {
        @($script:ExampleState.message_bus."phase.transition").Count | Should -Be 0
        @($script:ExampleState.message_bus."ci.status").Count | Should -Be 0
    }
}

Describe "state example runtime compatibility" {
    BeforeEach {
        $script:StatePath = Join-Path $TestDrive "state.json"
        Copy-Item -Path $script:ExamplePath -Destination $script:StatePath
    }

    It "TokenBudget からそのまま読める" {
        $token = Get-TokenState -StatePath $script:StatePath
        $token.remaining | Should -Be 100
        $token.current_phase_used | Should -Be 0
    }

    It "MessageBus のステータス集計にそのまま使える" {
        $status = @(Get-BusStatus -StatePath $script:StatePath)
        $status.Count | Should -Be 2
        ($status | Where-Object { $_.Topic -eq "phase.transition" }).PendingCount | Should -Be 0
        ($status | Where-Object { $_.Topic -eq "ci.status" }).PendingCount | Should -Be 0
    }
}

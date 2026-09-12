BeforeAll {
    Import-Module "$PSScriptRoot/../../scripts/lib/LauncherCommon.psm1" -Force -DisableNameChecking
}

Describe "Find-AvailableDriveLetter" {
    It "使用中のドライブレターを返さない" {
        $usedLetters = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name)
        $result = Find-AvailableDriveLetter
        if ($result) {
            $result | Should -Not -BeIn $usedLetters
        }
    }

    It "PreferredLetters の優先順で返す" {
        $usedLetters = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name)
        $preferred = @("P", "Q", "R")
        $result = Find-AvailableDriveLetter -PreferredLetters $preferred
        if ($result) {
            $expectedFirst = $preferred | Where-Object { $_ -notin $usedLetters } | Select-Object -First 1
            $result | Should -Be $expectedFirst
        }
    }

    It "ExcludeLetters で除外できる" {
        $result = Find-AvailableDriveLetter -PreferredLetters @("P", "Q") -ExcludeLetters @("P")
        if ($result) {
            $result | Should -Not -Be "P"
        }
    }
}

Describe "Get-LauncherModeName" {
    It "常に local を返す" {
        Get-LauncherModeName | Should -Be "local"
    }
}

Describe "Get-RegisteredProjectRoots" {
    It "registeredProjects.roots が定義されていればその順で返す" {
        $config = [pscustomobject]@{
            projectsDir        = "/home/kensan/Projects"
            registeredProjects = [pscustomobject]@{
                roots = @(
                    "/home/kensan/Projects/Mirai-Project",
                    "/home/kensan/Projects/Mirai-DX-Project"
                )
            }
        }

        $result = @(Get-RegisteredProjectRoots -Config $config)

        $result | Should -Be @(
            "/home/kensan/Projects/Mirai-Project",
            "/home/kensan/Projects/Mirai-DX-Project"
        )
    }

    It "roots が無い場合は projectsDir を単一ルートとして返す" {
        $config = [pscustomobject]@{
            projectsDir = "/home/kensan/Projects"
        }

        $result = @(Get-RegisteredProjectRoots -Config $config)

        $result | Should -Be @("/home/kensan/Projects")
    }
}

Describe "Resolve-ProjectPath" {
    It "明示された絶対パスを登録ルートと結合せず返す" {
        $projectPath = Join-Path $TestDrive "explicit [project]"
        New-Item -ItemType Directory -Path $projectPath -Force | Out-Null
        $config = [pscustomobject]@{ projectsDir = (Join-Path $TestDrive "elsewhere") }
        Resolve-ProjectPath -Config $config -ProjectName $projectPath | Should -BeExactly $projectPath
    }

    It "存在しない絶対パスまたはファイルを拒否する" {
        $config = [pscustomobject]@{ projectsDir = $TestDrive }
        $filePath = Join-Path $TestDrive "not-a-directory"
        Set-Content -LiteralPath $filePath -Value "fixture"
        { Resolve-ProjectPath -Config $config -ProjectName $filePath } | Should -Throw "*ディレクトリが見つかりません*"
        { Resolve-ProjectPath -Config $config -ProjectName (Join-Path $TestDrive "missing") } | Should -Throw "*ディレクトリが見つかりません*"
    }

    It "複数の登録ルートに同名プロジェクトがある場合は拒否する" {
        $roots = @((Join-Path $TestDrive "internal"), (Join-Path $TestDrive "external"))
        foreach ($root in $roots) { New-Item -ItemType Directory -Path (Join-Path $root "shared") -Force | Out-Null }
        $config = [pscustomobject]@{ projectsDir = $TestDrive; registeredProjects = [pscustomobject]@{ roots = $roots } }
        { Resolve-ProjectPath -Config $config -ProjectName "shared" } | Should -Throw "*プロジェクト名が曖昧*"
    }

    It "同じ登録ルートの重複は曖昧さとして扱わない" {
        $root = Join-Path $TestDrive "repeated"
        $projectPath = Join-Path $root "unique"
        New-Item -ItemType Directory -Path $projectPath -Force | Out-Null
        $config = [pscustomobject]@{ registeredProjects = [pscustomobject]@{ roots = @($root, "$root/.") } }
        Resolve-ProjectPath -Config $config -ProjectName "unique" | Should -BeExactly $projectPath
    }

    It "Linux の大文字小文字が異なる登録ルートを別パスとして扱う" {
        $roots = @((Join-Path $TestDrive "CaseRoot"), (Join-Path $TestDrive "caseroot"))
        foreach ($root in $roots) { New-Item -ItemType Directory -Path (Join-Path $root "same") -Force | Out-Null }
        $config = [pscustomobject]@{ registeredProjects = [pscustomobject]@{ roots = $roots } }
        { Resolve-ProjectPath -Config $config -ProjectName "same" } | Should -Throw "*プロジェクト名が曖昧*"
    }

    It "登録ルート配下のプロジェクトを解決する" {
        $internalRoot = Join-Path $TestDrive "Mirai-Project"
        $externalRoot = Join-Path $TestDrive "Mirai-DX-Project"
        New-Item -ItemType Directory -Path (Join-Path $externalRoot "Mirai-Info") -Force | Out-Null

        $config = [pscustomobject]@{
            projectsDir        = $TestDrive
            registeredProjects = [pscustomobject]@{
                roots = @($internalRoot, $externalRoot)
            }
        }

        Resolve-ProjectPath -Config $config -ProjectName "Mirai-Info" |
            Should -Be (Join-Path $externalRoot "Mirai-Info")
    }

    It "どの登録ルートにも無ければ projectsDir 配下のパスを返す" {
        $config = [pscustomobject]@{
            projectsDir        = $TestDrive
            registeredProjects = [pscustomobject]@{
                roots = @(Join-Path $TestDrive "Mirai-Project")
            }
        }

        Resolve-ProjectPath -Config $config -ProjectName "UnknownProject" |
            Should -Be (Join-Path $TestDrive "UnknownProject")
    }
}

Describe "Resolve-CodexLaunchArguments" {
    It "旧 --full-auto を現行 Codex の YOLO 相当オプションへ変換する" {
        $result = Resolve-CodexLaunchArguments -Arguments @("--full-auto")

        $result | Should -Be @("--dangerously-bypass-approvals-and-sandbox")
    }

    It "旧 --yolo alias を現行の明示オプションへ変換する" {
        $result = Resolve-CodexLaunchArguments -Arguments @("--yolo")

        $result | Should -Be @("--dangerously-bypass-approvals-and-sandbox")
    }

    It "その他の引数は保持する" {
        $result = Resolve-CodexLaunchArguments -Arguments @("--model", "gpt-5.5")

        $result | Should -Be @("--model", "gpt-5.5")
    }
}

Describe "ConvertTo-PosixShellArgument" {
    It "シングルクォートを POSIX shell 用にエスケープする" {
        ConvertTo-PosixShellArgument -Value "a'b" | Should -Be "'a'\''b'"
    }

    It "空文字をクォートする" {
        ConvertTo-PosixShellArgument -Value "" | Should -Be "''"
    }
}

Describe "Invoke-InteractiveNativeCommand" {
    It "指定ディレクトリで native command を実行し終了コードを返す" {
        $exitCode = Invoke-InteractiveNativeCommand `
            -FilePath "pwsh" `
            -Arguments @("-NoLogo", "-NoProfile", "-Command", "if ((Get-Location).Path -eq '$TestDrive') { exit 0 } else { exit 5 }") `
            -WorkingDirectory $TestDrive

        $exitCode | Should -Be 0
    }
}

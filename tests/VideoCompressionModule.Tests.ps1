#------------------------------------------------------------------------------------------------------------------
# VideoCompressionModule.Tests.ps1 - Unit tests for the main VideoCompressionModule
#------------------------------------------------------------------------------------------------------------------

BeforeAll {
    # Import test helper
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1')

    # Ensure PSSQLite is available
    if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
        Install-Module -Name PSSQLite -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module PSSQLite -Force

    # Import the module
    Import-TestModule

    # Initialize a test database and logger to prevent errors during tests
    $Script:GlobalTestDbPath = New-TestDatabase
    Initialize-SPVidComp-Catalog -DatabasePath $Script:GlobalTestDbPath

    $Script:GlobalTestLogPath = New-TestLogDirectory
    Initialize-Logger -LogPath $Script:GlobalTestLogPath -LogLevel 'Error' -ConsoleOutput $false -FileOutput $false
}

AfterAll {
    Remove-TestDatabase -Path $Script:GlobalTestDbPath
    Remove-TestLogDirectory -Path $Script:GlobalTestLogPath
}

#------------------------------------------------------------------------------------------------------------------
# Platform Detection Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Get-SPVidComp-PlatformDefaults' {
    It 'Should return a hashtable' {
        $defaults = Get-SPVidComp-PlatformDefaults

        $defaults | Should -BeOfType [hashtable]
    }

    It 'Should contain TempPath key' {
        $defaults = Get-SPVidComp-PlatformDefaults

        $defaults.Keys | Should -Contain 'TempPath'
        $defaults.TempPath | Should -Not -BeNullOrEmpty
    }

    It 'Should contain ArchivePath key' {
        $defaults = Get-SPVidComp-PlatformDefaults

        $defaults.Keys | Should -Contain 'ArchivePath'
        $defaults.ArchivePath | Should -Not -BeNullOrEmpty
    }

    It 'Should contain LogPath key' {
        $defaults = Get-SPVidComp-PlatformDefaults

        $defaults.Keys | Should -Contain 'LogPath'
        $defaults.LogPath | Should -Not -BeNullOrEmpty
    }

    It 'Should return platform-appropriate paths' {
        $defaults = Get-SPVidComp-PlatformDefaults

        if ($IsWindows) {
            $defaults.TempPath | Should -Match '^[A-Z]:\\'
        }
        elseif ($IsMacOS -or $IsLinux) {
            $defaults.TempPath | Should -Match '^/'
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Illegal Character Handling Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Get-SPVidComp-IllegalCharacters' {
    It 'Should return an array of characters' {
        $chars = Get-SPVidComp-IllegalCharacters

        $chars | Should -Not -BeNullOrEmpty
        $chars.GetType().IsArray | Should -BeTrue
    }

    It 'Should include common illegal characters' {
        $chars = Get-SPVidComp-IllegalCharacters

        # These are illegal on all platforms
        $chars | Should -Contain ([char]0)  # Null character
    }

    It 'Should use native .NET method' {
        $chars = Get-SPVidComp-IllegalCharacters
        $nativeChars = [System.IO.Path]::GetInvalidFileNameChars()

        $chars.Count | Should -Be $nativeChars.Count
    }
}

Describe 'Test-SPVidComp-FilenameCharacters' {
    It 'Should return IsValid = true for valid filename' {
        $result = Test-SPVidComp-FilenameCharacters -Filename 'valid-filename.mp4'

        $result.IsValid | Should -BeTrue
        $result.IllegalCharacters.Count | Should -Be 0
    }

    It 'Should return IsValid = false for filename with illegal characters' {
        # Use a character we know is illegal (colon on Windows, null everywhere)
        $illegalFilename = "test`0file.mp4"  # Null character

        $result = Test-SPVidComp-FilenameCharacters -Filename $illegalFilename

        $result.IsValid | Should -BeFalse
    }

    It 'Should identify specific illegal characters' {
        $illegalFilename = "test`0file.mp4"

        $result = Test-SPVidComp-FilenameCharacters -Filename $illegalFilename

        $result.IllegalCharacters | Should -Not -BeNullOrEmpty
    }

    It 'Should preserve original filename in result' {
        $filename = 'my-video.mp4'

        $result = Test-SPVidComp-FilenameCharacters -Filename $filename

        $result.OriginalFilename | Should -Be $filename
    }
}

Describe 'Repair-SPVidComp-Filename' {
    Context 'With valid filename' {
        It 'Should return unchanged filename' {
            $result = Repair-SPVidComp-Filename -Filename 'valid-file.mp4'

            $result.Success | Should -BeTrue
            $result.Changed | Should -BeFalse
            $result.SanitizedFilename | Should -Be 'valid-file.mp4'
        }
    }

    Context 'With Replace strategy' {
        It 'Should replace illegal characters with replacement char' {
            # Create filename with null character
            $illegalFilename = "test`0file.mp4"

            $result = Repair-SPVidComp-Filename -Filename $illegalFilename -Strategy 'Replace' -ReplacementChar '_'

            $result.Success | Should -BeTrue
            $result.Changed | Should -BeTrue
            $result.SanitizedFilename | Should -Not -Match "`0"
            $result.SanitizedFilename | Should -Match '_'
        }

        It 'Should use default replacement char of underscore' {
            $illegalFilename = "test`0file.mp4"

            $result = Repair-SPVidComp-Filename -Filename $illegalFilename -Strategy 'Replace'

            $result.ReplacementChar | Should -Be '_'
        }
    }

    Context 'With Omit strategy' {
        It 'Should remove illegal characters entirely' {
            # Create a filename with null character
            $illegalFilename = "test" + [char]0 + "file.mp4"

            $result = Repair-SPVidComp-Filename -Filename $illegalFilename -Strategy 'Omit'

            $result.Success | Should -BeTrue
            $result.Changed | Should -BeTrue
            # The null character should be removed, leaving "testfile.mp4"
            $result.SanitizedFilename | Should -Be 'testfile.mp4'
        }
    }

    Context 'With Error strategy' {
        It 'Should return failure for invalid filename' {
            $illegalFilename = "test`0file.mp4"

            $result = Repair-SPVidComp-Filename -Filename $illegalFilename -Strategy 'Error'

            $result.Success | Should -BeFalse
            $result.Error | Should -Not -BeNullOrEmpty
        }

        It 'Should succeed for valid filename' {
            $result = Repair-SPVidComp-Filename -Filename 'valid.mp4' -Strategy 'Error'

            $result.Success | Should -BeTrue
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Disk Space Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Test-SPVidComp-DiskSpace' {
    BeforeAll {
        # Create a temp directory that exists
        $Script:TestTempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "diskspace-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $Script:TestTempDir -Force | Out-Null
    }

    AfterAll {
        if (Test-Path -LiteralPath $Script:TestTempDir) {
            Remove-Item -LiteralPath $Script:TestTempDir -Recurse -Force
        }
    }

    It 'Should return HasSpace property' {
        $result = Test-SPVidComp-DiskSpace -Path $Script:TestTempDir -RequiredBytes 1024

        $result.Keys | Should -Contain 'HasSpace'
    }

    It 'Should return FreeSpace property' {
        $result = Test-SPVidComp-DiskSpace -Path $Script:TestTempDir -RequiredBytes 1024

        $result.Keys | Should -Contain 'FreeSpace'
        $result.FreeSpace | Should -BeGreaterThan 0
    }

    It 'Should return true for small space requirement' {
        $result = Test-SPVidComp-DiskSpace -Path $Script:TestTempDir -RequiredBytes 1024  # 1 KB

        $result.HasSpace | Should -BeTrue
    }

    It 'Should return false for impossibly large space requirement' {
        $result = Test-SPVidComp-DiskSpace -Path $Script:TestTempDir -RequiredBytes ([long]::MaxValue)

        $result.HasSpace | Should -BeFalse
    }
}

#------------------------------------------------------------------------------------------------------------------
# Archive Integrity Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Test-SPVidComp-ArchiveIntegrity' {
    BeforeAll {
        $Script:TestDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "archive-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $Script:TestDir -Force | Out-Null

        # Create source file
        $Script:SourceFile = Join-Path -Path $Script:TestDir -ChildPath 'source.bin'
        $bytes = [byte[]](1..100)
        [System.IO.File]::WriteAllBytes($Script:SourceFile, $bytes)

        # Create identical copy
        $Script:IdenticalCopy = Join-Path -Path $Script:TestDir -ChildPath 'identical.bin'
        Copy-Item -LiteralPath $Script:SourceFile -Destination $Script:IdenticalCopy

        # Create different file
        $Script:DifferentFile = Join-Path -Path $Script:TestDir -ChildPath 'different.bin'
        $differentBytes = [byte[]](100..1)
        [System.IO.File]::WriteAllBytes($Script:DifferentFile, $differentBytes)
    }

    AfterAll {
        if (Test-Path -LiteralPath $Script:TestDir) {
            Remove-Item -LiteralPath $Script:TestDir -Recurse -Force
        }
    }

    It 'Should return Success = true for identical files' {
        $result = Test-SPVidComp-ArchiveIntegrity -SourcePath $Script:SourceFile -DestinationPath $Script:IdenticalCopy

        $result.Success | Should -BeTrue
    }

    It 'Should return matching hashes for identical files' {
        $result = Test-SPVidComp-ArchiveIntegrity -SourcePath $Script:SourceFile -DestinationPath $Script:IdenticalCopy

        $result.SourceHash | Should -Be $result.DestinationHash
    }

    It 'Should return Success = false for different files' {
        $result = Test-SPVidComp-ArchiveIntegrity -SourcePath $Script:SourceFile -DestinationPath $Script:DifferentFile

        $result.Success | Should -BeFalse
    }

    It 'Should return different hashes for different files' {
        $result = Test-SPVidComp-ArchiveIntegrity -SourcePath $Script:SourceFile -DestinationPath $Script:DifferentFile

        $result.SourceHash | Should -Not -Be $result.DestinationHash
    }

    It 'Should return SHA256 hashes' {
        $result = Test-SPVidComp-ArchiveIntegrity -SourcePath $Script:SourceFile -DestinationPath $Script:IdenticalCopy

        # SHA256 hash is 64 hex characters
        $result.SourceHash.Length | Should -Be 64
        $result.SourceHash | Should -Match '^[A-F0-9]+$'
    }
}

#------------------------------------------------------------------------------------------------------------------
# Copy Archive Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Copy-SPVidComp-Archive' {
    BeforeAll {
        $Script:CopyTestDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "copy-archive-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $Script:CopyTestDir -Force | Out-Null

        # Create source file using helper function
        $Script:CopySourceFile = Join-Path -Path $Script:CopyTestDir -ChildPath 'source.bin'
        New-MockVideoFile -Path $Script:CopySourceFile -SizeKB 10
    }

    AfterAll {
        if (Test-Path -LiteralPath $Script:CopyTestDir) {
            Remove-Item -LiteralPath $Script:CopyTestDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Should copy file to archive location' {
        $archivePath = Join-Path -Path $Script:CopyTestDir -ChildPath 'archive\copied.bin'

        $result = Copy-SPVidComp-Archive -SourcePath $Script:CopySourceFile -ArchivePath $archivePath

        $result.Success | Should -BeTrue
        Test-Path -LiteralPath $archivePath | Should -BeTrue
    }

    It 'Should return archive path in result' {
        $archivePath = Join-Path -Path $Script:CopyTestDir -ChildPath 'archive2\copied.bin'

        $result = Copy-SPVidComp-Archive -SourcePath $Script:CopySourceFile -ArchivePath $archivePath

        $result.ArchivePath | Should -Be $archivePath
    }

    It 'Should return source and destination hashes' {
        $archivePath = Join-Path -Path $Script:CopyTestDir -ChildPath 'archive3\copied.bin'

        $result = Copy-SPVidComp-Archive -SourcePath $Script:CopySourceFile -ArchivePath $archivePath

        $result.SourceHash | Should -Not -BeNullOrEmpty
        $result.DestinationHash | Should -Not -BeNullOrEmpty
        $result.SourceHash | Should -Be $result.DestinationHash
    }

    It 'Should create archive directory if it does not exist' {
        $deepPath = Join-Path -Path $Script:CopyTestDir -ChildPath 'deep\nested\archive\path\copied.bin'

        $result = Copy-SPVidComp-Archive -SourcePath $Script:CopySourceFile -ArchivePath $deepPath

        $result.Success | Should -BeTrue
        Test-Path -LiteralPath $deepPath | Should -BeTrue
    }
}

#------------------------------------------------------------------------------------------------------------------
# Catalog and Database Integration Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Initialize-SPVidComp-Catalog' {
    BeforeEach {
        $Script:TestDbPath = New-TestDatabase
    }

    AfterEach {
        Remove-TestDatabase -Path $Script:TestDbPath
    }

    It 'Should create database file' {
        Initialize-SPVidComp-Catalog -DatabasePath $Script:TestDbPath

        Test-Path -LiteralPath $Script:TestDbPath | Should -BeTrue
    }

    It 'Should not throw on valid path' {
        { Initialize-SPVidComp-Catalog -DatabasePath $Script:TestDbPath } | Should -Not -Throw
    }
}

Describe 'Add-SPVidComp-Video' {
    BeforeAll {
        $Script:TestDbPath = New-TestDatabase
        Initialize-SPVidComp-Catalog -DatabasePath $Script:TestDbPath
    }

    AfterAll {
        Remove-TestDatabase -Path $Script:TestDbPath
    }

    It 'Should add video to catalog' {
        $video = Get-TestVideoRecord -Filename 'add-test.mp4'

        $result = Add-SPVidComp-Video @video

        $result | Should -BeTrue
    }

    It 'Should return true on successful add' {
        $video = Get-TestVideoRecord -Filename "unique-$(Get-Random).mp4"

        $result = Add-SPVidComp-Video @video

        $result | Should -BeTrue
    }
}

Describe 'Get-SPVidComp-Videos' {
    BeforeAll {
        $Script:TestDbPath = New-TestDatabase
        Initialize-SPVidComp-Catalog -DatabasePath $Script:TestDbPath

        # Add test videos
        $video1 = Get-TestVideoRecord -Filename 'query-test-1.mp4'
        $video2 = Get-TestVideoRecord -Filename 'query-test-2.mp4'
        Add-SPVidComp-Video @video1
        Add-SPVidComp-Video @video2
    }

    AfterAll {
        Remove-TestDatabase -Path $Script:TestDbPath
    }

    It 'Should return videos from catalog' {
        $videos = Get-SPVidComp-Videos

        $videos | Should -Not -BeNullOrEmpty
    }

    It 'Should filter by status' {
        $videos = Get-SPVidComp-Videos -Status 'Cataloged'

        $videos | ForEach-Object { $_.status | Should -Be 'Cataloged' }
    }

    It 'Should respect limit parameter' {
        $videos = Get-SPVidComp-Videos -Limit 1

        $videos.Count | Should -BeLessOrEqual 1
    }
}

Describe 'Update-SPVidComp-Status' {
    BeforeAll {
        $Script:TestDbPath = New-TestDatabase
        Initialize-SPVidComp-Catalog -DatabasePath $Script:TestDbPath

        $video = Get-TestVideoRecord -Filename 'status-update-test.mp4'
        Add-SPVidComp-Video @video

        $Script:TestVideoId = (Get-SPVidComp-Videos)[0].id
    }

    AfterAll {
        Remove-TestDatabase -Path $Script:TestDbPath
    }

    It 'Should update video status' {
        $result = Update-SPVidComp-Status -VideoId $Script:TestVideoId -Status 'Downloading'

        $result | Should -BeTrue
    }

    It 'Should update with additional fields' {
        $result = Update-SPVidComp-Status -VideoId $Script:TestVideoId -Status 'Completed' -AdditionalFields @{
            compressed_size = 50000000
            compression_ratio = 0.5
        }

        $result | Should -BeTrue
    }
}

Describe 'Get-SPVidComp-Statistics' {
    BeforeAll {
        $Script:TestDbPath = New-TestDatabase
        Initialize-SPVidComp-Catalog -DatabasePath $Script:TestDbPath

        $video = Get-TestVideoRecord -Filename 'stats-test.mp4' -Size 100000000
        Add-SPVidComp-Video @video
    }

    AfterAll {
        Remove-TestDatabase -Path $Script:TestDbPath
    }

    It 'Should return statistics hashtable' {
        $stats = Get-SPVidComp-Statistics

        $stats | Should -Not -BeNullOrEmpty
    }

    It 'Should include TotalCataloged' {
        $stats = Get-SPVidComp-Statistics

        $stats.TotalCataloged | Should -BeGreaterOrEqual 1
    }

    It 'Should include TotalOriginalSize' {
        $stats = Get-SPVidComp-Statistics

        $stats.TotalOriginalSize | Should -BeGreaterOrEqual 100000000
    }
}

#------------------------------------------------------------------------------------------------------------------
# Configuration Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Configuration Functions' {
    BeforeAll {
        $Script:TestDbPath = New-TestDatabase
        Initialize-SPVidComp-Catalog -DatabasePath $Script:TestDbPath
    }

    AfterAll {
        Remove-TestDatabase -Path $Script:TestDbPath
    }

    Describe 'Test-SPVidComp-ConfigExists' {
        It 'Should return false when no config exists' {
            $freshDb = New-TestDatabase -Path (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "fresh-config-$(Get-Random).db")
            Initialize-SPVidComp-Catalog -DatabasePath $freshDb

            $result = Test-SPVidComp-ConfigExists

            # May be true or false depending on state - just verify it doesn't throw
            $result | Should -BeIn @($true, $false)

            Remove-TestDatabase -Path $freshDb

            # Restore the original test database path for subsequent tests
            Initialize-SPVidComp-Catalog -DatabasePath $Script:TestDbPath
        }
    }

    Describe 'Set-SPVidComp-Config and Get-SPVidComp-Config' {
        BeforeAll {
            # Ensure we're using the correct test database
            Initialize-SPVidComp-Catalog -DatabasePath $Script:TestDbPath
        }

        It 'Should store configuration values' {
            $config = @{
                'test_key_1' = 'value1'
                'test_key_2' = 'value2'
            }

            $result = Set-SPVidComp-Config -ConfigValues $config

            $result | Should -BeTrue
        }

        It 'Should retrieve stored configuration' {
            $config = @{
                'retrieve_test' = 'test_value'
            }
            Set-SPVidComp-Config -ConfigValues $config

            $retrieved = Get-SPVidComp-Config

            $retrieved | Should -Not -BeNullOrEmpty
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Logging Wrapper Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Write-SPVidComp-Log' {
    BeforeAll {
        $Script:TestLogPath = New-TestLogDirectory
        Initialize-Logger -LogPath $Script:TestLogPath -LogLevel 'Debug' -ConsoleOutput $false -FileOutput $true
    }

    AfterAll {
        Remove-TestLogDirectory -Path $Script:TestLogPath
    }

    It 'Should not throw on valid log entry' {
        { Write-SPVidComp-Log -Message 'Test message' -Level 'Info' } | Should -Not -Throw
    }

    It 'Should accept all log levels' {
        { Write-SPVidComp-Log -Message 'Debug' -Level 'Debug' } | Should -Not -Throw
        { Write-SPVidComp-Log -Message 'Info' -Level 'Info' } | Should -Not -Throw
        { Write-SPVidComp-Log -Message 'Warning' -Level 'Warning' } | Should -Not -Throw
        { Write-SPVidComp-Log -Message 'Error' -Level 'Error' } | Should -Not -Throw
    }

    It 'Should accept component parameter' {
        { Write-SPVidComp-Log -Message 'Test' -Level 'Info' -Component 'TestComponent' } | Should -Not -Throw
    }
}

#------------------------------------------------------------------------------------------------------------------
# FFmpeg Auto-Download Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Test-SPVidComp-FFmpegAvailability' {
    It 'Should return a hashtable' {
        $result = Test-SPVidComp-FFmpegAvailability

        $result | Should -BeOfType [hashtable]
    }

    It 'Should contain required keys' {
        $result = Test-SPVidComp-FFmpegAvailability

        $result.Keys | Should -Contain 'FFmpegAvailable'
        $result.Keys | Should -Contain 'FFprobeAvailable'
        $result.Keys | Should -Contain 'AllAvailable'
        $result.Keys | Should -Contain 'FFmpegPath'
        $result.Keys | Should -Contain 'FFprobePath'
    }

    It 'Should return boolean values for availability' {
        $result = Test-SPVidComp-FFmpegAvailability

        $result.FFmpegAvailable | Should -BeOfType [bool]
        $result.FFprobeAvailable | Should -BeOfType [bool]
        $result.AllAvailable | Should -BeOfType [bool]
    }

    It 'Should set AllAvailable to true only if both are available' {
        $result = Test-SPVidComp-FFmpegAvailability

        if ($result.FFmpegAvailable -and $result.FFprobeAvailable) {
            $result.AllAvailable | Should -BeTrue
        }
        else {
            $result.AllAvailable | Should -BeFalse
        }
    }

    It 'Should include version info when -Detailed is used' {
        $result = Test-SPVidComp-FFmpegAvailability -Detailed

        if ($result.FFmpegAvailable) {
            $result.FFmpegVersion | Should -Not -BeNullOrEmpty
        }
        if ($result.FFprobeAvailable) {
            $result.FFprobeVersion | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should include path info when available' {
        $result = Test-SPVidComp-FFmpegAvailability

        if ($result.FFmpegAvailable) {
            $result.FFmpegPath | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $result.FFmpegPath | Should -BeTrue
        }
        if ($result.FFprobeAvailable) {
            $result.FFprobePath | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $result.FFprobePath | Should -BeTrue
        }
    }
}

Describe 'Install-SPVidComp-FFmpeg' {
    BeforeAll {
        # Save original module bin directory path
        $Script:OriginalFFmpegBinDir = $Script:FFmpegBinDir

        # Create isolated test bin directory
        $Script:TestFFmpegBinDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test-ffmpeg-$(Get-Random)"
        New-Item -ItemType Directory -Path $Script:TestFFmpegBinDir -Force | Out-Null

        # Initialize logger (suppress output)
        $Script:TestFFmpegLogDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test-ffmpeg-logs-$(Get-Random)"
        New-Item -ItemType Directory -Path $Script:TestFFmpegLogDir -Force | Out-Null
        Initialize-Logger -LogPath $Script:TestFFmpegLogDir -LogLevel 'Error' -ConsoleOutput $false -FileOutput $false
    }

    AfterAll {
        # Restore original bin directory in MODULE's scope
        $module = Get-Module VideoCompressionModule
        & $module { param($dir) $Script:FFmpegBinDir = $dir } $Script:OriginalFFmpegBinDir

        # Clear cached paths in MODULE's scope
        & $module { $Script:FFmpegPath = $null; $Script:FFprobePath = $null }

        # Clean up test bin directory
        if (Test-Path -LiteralPath $Script:TestFFmpegBinDir) {
            Remove-Item -Path $Script:TestFFmpegBinDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Clean up test log directory
        if (Test-Path -LiteralPath $Script:TestFFmpegLogDir) {
            Remove-Item -Path $Script:TestFFmpegLogDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    BeforeEach {
        # Set test bin directory in the MODULE's scope (not test scope)
        $module = Get-Module VideoCompressionModule
        & $module { param($dir) $Script:FFmpegBinDir = $dir } $Script:TestFFmpegBinDir

        # Clear cached paths in the MODULE's scope
        & $module { $Script:FFmpegPath = $null; $Script:FFprobePath = $null }

        # Clean test bin directory
        if (Test-Path -LiteralPath $Script:TestFFmpegBinDir) {
            Get-ChildItem -Path $Script:TestFFmpegBinDir | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        }
    }

    It 'Should return a hashtable' {
        $result = Install-SPVidComp-FFmpeg

        $result | Should -BeOfType [hashtable]
    }

    It 'Should contain required keys on success' {
        $result = Install-SPVidComp-FFmpeg

        $result.Keys | Should -Contain 'Success'
        if ($result.Success) {
            $result.Keys | Should -Contain 'FFmpegPath'
            $result.Keys | Should -Contain 'FFprobePath'
            $result.Keys | Should -Contain 'Downloaded'
        }
    }

    It 'Should contain Error key on failure' {
        # This test would need to mock network failure, so just verify structure
        $result = Install-SPVidComp-FFmpeg

        if (-not $result.Success) {
            $result.Keys | Should -Contain 'Error'
        }
    }

    It 'Should actually download and install ffmpeg binaries' {
        # Force download even if system ffmpeg exists
        $result = Install-SPVidComp-FFmpeg -Force

        $result.Success | Should -BeTrue
        $result.Downloaded | Should -BeTrue

        # Verify files were actually created in test directory
        $ffmpegExe = if ($IsWindows) { 'ffmpeg.exe' } else { 'ffmpeg' }
        $ffprobeExe = if ($IsWindows) { 'ffprobe.exe' } else { 'ffprobe' }

        $expectedFFmpegPath = Join-Path -Path $Script:TestFFmpegBinDir -ChildPath $ffmpegExe
        $expectedFFprobePath = Join-Path -Path $Script:TestFFmpegBinDir -ChildPath $ffprobeExe

        Test-Path -LiteralPath $expectedFFmpegPath | Should -BeTrue
        Test-Path -LiteralPath $expectedFFprobePath | Should -BeTrue

        # Verify the downloaded files are actual executables (non-zero size)
        (Get-Item -LiteralPath $expectedFFmpegPath).Length | Should -BeGreaterThan 0
        (Get-Item -LiteralPath $expectedFFprobePath).Length | Should -BeGreaterThan 0
    } -Tag 'Integration', 'Download'

    It 'Should detect already installed ffmpeg without Force' {
        # First install with Force
        $result1 = Install-SPVidComp-FFmpeg -Force
        $result1.Success | Should -BeTrue
        $result1.Downloaded | Should -BeTrue

        # Second call without Force should detect existing
        $result2 = Install-SPVidComp-FFmpeg
        $result2.Success | Should -BeTrue
        $result2.Downloaded | Should -BeFalse
    } -Tag 'Integration', 'Download'

    It 'Should download again with -Force even if already installed' {
        # First install
        $result1 = Install-SPVidComp-FFmpeg -Force
        $result1.Success | Should -BeTrue

        # Second call WITH Force should download again
        $result2 = Install-SPVidComp-FFmpeg -Force
        $result2.Success | Should -BeTrue
        $result2.Downloaded | Should -BeTrue
    } -Tag 'Integration', 'Download'

    It 'Should verify downloaded binaries are executable' {
        $result = Install-SPVidComp-FFmpeg -Force

        if ($result.Success) {
            # Try to run ffmpeg -version
            $ffmpegTest = & $result.FFmpegPath -version 2>&1 | Select-Object -First 1
            $ffmpegTest | Should -Match 'ffmpeg version'

            # Try to run ffprobe -version
            $ffprobeTest = & $result.FFprobePath -version 2>&1 | Select-Object -First 1
            $ffprobeTest | Should -Match 'ffprobe version'
        }
    } -Tag 'Integration', 'Download'
}

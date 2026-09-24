function Get-TeacherPcmHash {
    param([string]$SessionDir,[System.Collections.IDictionary]$Manifest)
    $hasher=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $buffer=[byte[]]::new(65536)
    try {
        foreach($part in ($Manifest.files | Where-Object role -eq 'r' | Sort-Object part)) {
            $stream=[IO.File]::OpenRead((Join-Path $SessionDir $part.path))
            try {
                if ($stream.Length -ne [int64]$part.byte_count -or $stream.Length -lt 44) { throw 'Invalid WAV part length' }
                $stream.Position=44
                while(($count=$stream.Read($buffer,0,$buffer.Length)) -gt 0) {
                    $hasher.AppendData($buffer,0,$count)
                }
            } finally { $stream.Dispose() }
        }
        return [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
    } finally { $hasher.Dispose() }
}

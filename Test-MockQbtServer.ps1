#Requires -Version 5.1
# Minimal qBittorrent WebAPI mock over raw TCP (no URL ACL needed, runs unprivileged).
param(
    [int]$Port = 18080,
    [string]$StateFile = (Join-Path $env:TEMP 'pps-mock-state.json'),
    [int]$MaxRequests = 60
)

$ErrorActionPreference = 'Stop'
$state = @{ listen_port = 51274; random_port = $false; upnp = $true; natpmp = $false; logins = 0; last_body = '' }
$state | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()

$handled = 0
while ($handled -lt $MaxRequests) {
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $reader = [System.IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)

        $requestLine = $reader.ReadLine()
        if (-not $requestLine) { continue }
        $parts = $requestLine.Split(' ')
        $method = $parts[0]; $path = $parts[1]

        $headers = @{}
        while ($true) {
            $h = $reader.ReadLine()
            if (-not $h) { break }
            $i = $h.IndexOf(':')
            if ($i -gt 0) { $headers[$h.Substring(0,$i).Trim()] = $h.Substring($i+1).Trim() }
        }
        $body = ''
        if ($headers['Content-Length']) {
            $n = [int]$headers['Content-Length']
            $buf = New-Object char[] $n
            $read = 0
            while ($read -lt $n) {
                $r = $reader.Read($buf, $read, $n - $read)
                if ($r -le 0) { break }
                $read += $r
            }
            $body = -join $buf[0..($read-1)]
        }

        $cookie = $headers['Cookie']
        $authed = $cookie -and $cookie -match 'SID=abc123'
        $setCookie = ''
        $status = '200 OK'
        $ctype = 'text/plain'
        $payload = ''

        switch -Regex ("$method $path") {
            '^POST /api/v2/auth/login' {
                $form = @{}
                foreach ($pair in ($body -split '&')) {
                    $kv = $pair -split '=', 2
                    if ($kv.Count -eq 2) { $form[[uri]::UnescapeDataString($kv[0])] = [uri]::UnescapeDataString($kv[1]) }
                }
                if ($form['username'] -eq 'admin' -and $form['password'] -eq 'secret') {
                    $payload = ''          # qBittorrent 5.x: 200 with an empty body
                    $setCookie = 'SID=abc123; path=/'
                    $state.logins++
                } else {
                    $status = '401 Unauthorized'
                    $payload = 'Fails.'
                }
            }
            '^GET /api/v2/app/version' { $payload = 'v5.2.3' }
            '^GET /api/v2/app/preferences' {
                if (-not $authed) { $status = '403 Forbidden'; $payload = 'Forbidden' }
                else {
                    $ctype = 'application/json'
                    $payload = (@{ listen_port = $state.listen_port; random_port = $state.random_port
                                    upnp = $state.upnp; natpmp = $state.natpmp } | ConvertTo-Json -Compress)
                }
            }
            '^POST /api/v2/app/setPreferences' {
                if (-not $authed) { $status = '403 Forbidden'; $payload = 'Forbidden' }
                else {
                    $json = ($body -split '&' | Where-Object { $_ -like 'json=*' }) -replace '^json=', ''
                    $json = [uri]::UnescapeDataString(($json -replace '\+',' '))
                    $state.last_body = $json
                    $obj = $json | ConvertFrom-Json
                    if ($null -ne $obj.listen_port) { $state.listen_port = [int]$obj.listen_port }
                    $payload = ''
                }
            }
            '^POST /api/v2/app/shutdown' { $payload = '' }
            default { $status = '404 Not Found'; $payload = 'nope' }
        }

        $state | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8

        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $head = "HTTP/1.1 $status`r`nContent-Type: $ctype`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n"
        if ($setCookie) { $head += "Set-Cookie: $setCookie`r`n" }
        $head += "`r`n"
        $hb = [Text.Encoding]::ASCII.GetBytes($head)
        $stream.Write($hb, 0, $hb.Length)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $handled++
    }
    catch { }
    finally { $client.Close() }
}
$listener.Stop()

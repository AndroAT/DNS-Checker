# DNS Checker Script
# This script reads domains from a CSV file, performs DNS lookups, and exports results to CSV

# Function to convert IDN (Internationalized Domain Name) to Punycode
function ConvertTo-Punycode {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Domain
    )
    
    # Use .NET IdnMapping class to convert IDN to Punycode
    $idn = New-Object System.Globalization.IdnMapping
    
    try {
        # Split domain into parts and convert each part
        $domainParts = $Domain.Split('.')
        $punyParts = @()
        
        foreach ($part in $domainParts) {
            # Check if part contains non-ASCII characters
            if ($part -match '[^\x00-\x7F]') {
                $punyParts += $idn.GetAscii($part)
            } else {
                $punyParts += $part
            }
        }
        
        # Join parts back together
        $punycodeResult = $punyParts -join '.'
        return $punycodeResult
    }
    catch {
        Write-Warning "Could not convert domain to Punycode: $Domain. Error: $_"
        return $Domain # Return original if conversion fails
    }
}

# Function to get DNS records for a domain
function Get-DomainDnsRecords {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Domain
    )
    
    # Using New-Object instead of PSCustomObject for better compatibility
    $result = New-Object -TypeName PSObject
    Add-Member -InputObject $result -MemberType NoteProperty -Name "Domain" -Value $Domain
    Add-Member -InputObject $result -MemberType NoteProperty -Name "Nameserver" -Value "none"
    Add-Member -InputObject $result -MemberType NoteProperty -Name "MX" -Value "none"
    Add-Member -InputObject $result -MemberType NoteProperty -Name "SPF" -Value "none"
    Add-Member -InputObject $result -MemberType NoteProperty -Name "DMARC" -Value "none"
    
    try {
        # Convert domain to Punycode if it contains non-ASCII characters
        $lookupDomain = ConvertTo-Punycode -Domain $Domain
        
        # Get NS (Nameserver) records
        $nsRecords = Resolve-DnsName -Name $lookupDomain -Type NS -ErrorAction SilentlyContinue
        if ($nsRecords) {
            $result.Nameserver = ($nsRecords.NameHost -join ", ")
        }
        
        # Get MX records
        $mxRecords = Resolve-DnsName -Name $lookupDomain -Type MX -ErrorAction SilentlyContinue
        if ($mxRecords) {
            $result.MX = ($mxRecords | ForEach-Object { "$($_.NameExchange) (Preference: $($_.Preference))" } | Sort-Object -Property @{Expression={[int]($_ -split "Preference: ")[1].TrimEnd(')')}}) -join ", "
        }
        
        # Get SPF records (stored as TXT)
        $txtRecords = Resolve-DnsName -Name $lookupDomain -Type TXT -ErrorAction SilentlyContinue
        if ($txtRecords) {
            $spfRecord = $txtRecords | Where-Object { $_.Strings -match "v=spf1" }
            if ($spfRecord) {
                $result.SPF = ($spfRecord.Strings -join " ")
            }
        }
        
        # Get DMARC records (stored as TXT at _dmarc subdomain)
        $dmarcDomain = "_dmarc.$lookupDomain"
        $dmarcRecords = Resolve-DnsName -Name $dmarcDomain -Type TXT -ErrorAction SilentlyContinue
        if ($dmarcRecords) {
            $dmarcRecord = $dmarcRecords | Where-Object { $_.Strings -match "v=DMARC1" }
            if ($dmarcRecord) {
                $result.DMARC = ($dmarcRecord.Strings -join " ")
            }
        }
    }
    catch {
        Write-Warning "Error processing domain $Domain : $_"
    }
    
    return $result
}

# Main script execution
function Start-DnsCheck {
    param (
        [Parameter(Mandatory = $true)]
        [string]$CsvPath,
        
        [Parameter(Mandatory = $false)]
        [string]$OutputPath
    )
    
    # Check if CSV file exists
    if (-not (Test-Path $CsvPath)) {
        Write-Error "CSV file not found at path: $CsvPath"
        return
    }
    
    # Import domains from CSV
    try {
        $domains = Import-Csv -Path $CsvPath
        
        # Check if the CSV has a Domain column
        $domainColumn = $domains | Get-Member -MemberType NoteProperty | Select-Object -First 1 -ExpandProperty Name
        
        # Initialize results array
        $results = @()
        
        # Process each domain
        $totalDomains = $domains.Count
        $currentDomain = 0
        
        foreach ($row in $domains) {
            $currentDomain++
            $domain = $row.$domainColumn
            
            Write-Progress -Activity "Processing DNS Records" -Status "Domain: $domain" -PercentComplete (($currentDomain / $totalDomains) * 100)
            
            Write-Host "Processing domain: $domain"
            $dnsInfo = Get-DomainDnsRecords -Domain $domain
            $results += $dnsInfo
        }
        
        # Export results to CSV
        $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        
        Write-Host "Process completed. Results exported to: $OutputPath"
    }
    catch {
        Write-Error "Error processing CSV or exporting results: $_"
    }
}

# Get the script directory
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path

# Get input CSV path from user
Write-Host "========================================"
Write-Host "DNS CHECKER - Domain DNS Record Analysis"
Write-Host "========================================"
Write-Host "Dieses Skript analysiert Domains aus einer CSV-Datei und exportiert DNS-Informationen."
Write-Host ""

$csvPath = Read-Host "Geben Sie den Pfad zur CSV-Datei mit den Domains ein"

# Generate output path in the same directory as the script
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$outputFileName = "DomainDnsResults_$timestamp.csv"
$outputPath = Join-Path -Path $scriptPath -ChildPath $outputFileName

# Run the DNS check
Write-Host "Starte Analyse..."
Start-DnsCheck -CsvPath $csvPath -OutputPath $outputPath

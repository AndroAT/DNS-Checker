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
    
    # Create a hashtable for results (most compatible approach)
    $result = @{}
    $result.Domain = $Domain
    $result.Nameserver = "none"
    $result.MX = "none"
    $result.SPF = "none"
    $result.DMARC = "none"
    
    try {
        # Convert domain to Punycode if it contains non-ASCII characters
        $lookupDomain = ConvertTo-Punycode -Domain $Domain
        
        # Get NS (Nameserver) records
        $nsRecords = Resolve-DnsName -Name $lookupDomain -Type NS -ErrorAction SilentlyContinue
        if ($nsRecords) {
            $nsValues = @()
            foreach ($record in $nsRecords) {
                if ($record.NameHost) {
                    $nsValues += $record.NameHost
                }
            }
            if ($nsValues.Count -gt 0) {
                $result.Nameserver = [string]::Join(", ", $nsValues)
            }
        }
        
        # Get MX records
        $mxRecords = Resolve-DnsName -Name $lookupDomain -Type MX -ErrorAction SilentlyContinue
        if ($mxRecords) {
            $mxValues = @()
            foreach ($record in $mxRecords) {
                if ($record.NameExchange) {
                    $mxValues += "$($record.NameExchange) (Preference: $($record.Preference))"
                }
            }
            if ($mxValues.Count -gt 0) {
                $result.MX = [string]::Join(", ", $mxValues)
            }
        }
        
        # Get SPF records (stored as TXT)
        $txtRecords = Resolve-DnsName -Name $lookupDomain -Type TXT -ErrorAction SilentlyContinue
        if ($txtRecords) {
            foreach ($record in $txtRecords) {
                if ($record.Strings -match "v=spf1") {
                    $result.SPF = [string]::Join(" ", $record.Strings)
                    break
                }
            }
        }
        
        # Get DMARC records (stored as TXT at _dmarc subdomain)
        $dmarcDomain = "_dmarc.$lookupDomain"
        $dmarcRecords = Resolve-DnsName -Name $dmarcDomain -Type TXT -ErrorAction SilentlyContinue
        if ($dmarcRecords) {
            foreach ($record in $dmarcRecords) {
                if ($record.Strings -match "v=DMARC1") {
                    $result.DMARC = [string]::Join(" ", $record.Strings)
                    break
                }
            }
        }
    }
    catch {
        Write-Warning "Error processing domain $Domain : $_"
    }
    
    # Convert hashtable to CSV-friendly object
    $obj = New-Object PSObject
    foreach ($key in $result.Keys) {
        $obj | Add-Member -MemberType NoteProperty -Name $key -Value $result[$key]
    }
    
    return $obj
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
        
        # Check if the CSV has columns
        $properties = $domains | Get-Member -MemberType NoteProperty
        if (-not $properties) {
            Write-Error "CSV file does not contain any data or columns"
            return
        }
        
        # Get the first column name
        $domainColumn = $properties | Select-Object -First 1 -ExpandProperty Name
        
        # Initialize results array
        $results = @()
        
        # Process each domain
        $totalDomains = @($domains).Count
        $currentDomain = 0
        
        foreach ($row in $domains) {
            $currentDomain++
            $domain = $row.$domainColumn
            
            # Skip empty domains
            if ([string]::IsNullOrWhiteSpace($domain)) {
                Write-Warning "Skipping empty domain at row $currentDomain"
                continue
            }
            
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

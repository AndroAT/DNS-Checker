# DNS Checker Script
# This script reads domains from a CSV file, performs DNS lookups, and exports results to CSV
# Designed for maximum compatibility with restricted language modes

# Set error action preference
$ErrorActionPreference = "SilentlyContinue"

# Function to convert IDN (Internationalized Domain Name) to Punycode
function ConvertTo-Punycode {
    param (
        [string]$Domain
    )
    
    try {
        # Use .NET IdnMapping class to convert IDN to Punycode
        $idn = New-Object System.Globalization.IdnMapping
        
        # Split domain into parts and convert each part
        $domainParts = $Domain.Split('.')
        $punyParts = @()
        
        for ($i = 0; $i -lt $domainParts.Length; $i++) {
            $part = $domainParts[$i]
            # Check if part contains non-ASCII characters
            if ($part -match '[^\x00-\x7F]') {
                $punyParts += $idn.GetAscii($part)
            } else {
                $punyParts += $part
            }
        }
        
        # Join parts back together
        $punycodeResult = [String]::Join(".", $punyParts)
        return $punycodeResult
    }
    catch {
        Write-Host "Could not convert domain to Punycode: $Domain"
        return $Domain # Return original if conversion fails
    }
}

# Function to get nameserver records
function Get-NameserverRecords {
    param (
        [string]$Domain
    )
    
    try {
        $nsRecords = Resolve-DnsName -Name $Domain -Type NS -ErrorAction SilentlyContinue
        $nsValues = @()
        
        if ($nsRecords -ne $null) {
            for ($i = 0; $i -lt $nsRecords.Length; $i++) {
                if ($nsRecords[$i].NameHost -ne $null) {
                    $nsValues += $nsRecords[$i].NameHost
                }
            }
        }
        
        if ($nsValues.Count -gt 0) {
            return [String]::Join(", ", $nsValues)
        }
    } catch {
        Write-Host "Error getting NS records for $Domain"
    }
    
    return "none"
}

# Function to get MX records
function Get-MXRecords {
    param (
        [string]$Domain
    )
    
    try {
        $mxRecords = Resolve-DnsName -Name $Domain -Type MX -ErrorAction SilentlyContinue
        $mxValues = @()
        
        if ($mxRecords -ne $null) {
            for ($i = 0; $i -lt $mxRecords.Length; $i++) {
                if ($mxRecords[$i].NameExchange -ne $null) {
                    $mxValues += "$($mxRecords[$i].NameExchange) (Preference: $($mxRecords[$i].Preference))"
                }
            }
        }
        
        if ($mxValues.Count -gt 0) {
            return [String]::Join(", ", $mxValues)
        }
    } catch {
        Write-Host "Error getting MX records for $Domain"
    }
    
    return "none"
}

# Function to get SPF record
function Get-SPFRecord {
    param (
        [string]$Domain
    )
    
    try {
        $txtRecords = Resolve-DnsName -Name $Domain -Type TXT -ErrorAction SilentlyContinue
        
        if ($txtRecords -ne $null) {
            for ($i = 0; $i -lt $txtRecords.Length; $i++) {
                if ($txtRecords[$i].Strings -ne $null) {
                    $txtValue = [String]::Join(" ", $txtRecords[$i].Strings)
                    if ($txtValue -match "v=spf1") {
                        return $txtValue
                    }
                }
            }
        }
    } catch {
        Write-Host "Error getting SPF record for $Domain"
    }
    
    return "none"
}

# Function to get DMARC record
function Get-DMARCRecord {
    param (
        [string]$Domain
    )
    
    try {
        $dmarcDomain = "_dmarc.$Domain"
        $dmarcRecords = Resolve-DnsName -Name $dmarcDomain -Type TXT -ErrorAction SilentlyContinue
        
        if ($dmarcRecords -ne $null) {
            for ($i = 0; $i -lt $dmarcRecords.Length; $i++) {
                if ($dmarcRecords[$i].Strings -ne $null) {
                    $dmarcValue = [String]::Join(" ", $dmarcRecords[$i].Strings)
                    if ($dmarcValue -match "v=DMARC1") {
                        return $dmarcValue
                    }
                }
            }
        }
    } catch {
        Write-Host "Error getting DMARC record for $Domain"
    }
    
    return "none"
}

# Main function
function Start-DNSCheck {
    param (
        [string]$CsvPath,
        [string]$OutputPath
    )
    
    # Check if CSV file exists
    if (-not (Test-Path $CsvPath)) {
        Write-Host "CSV file not found at path: $CsvPath"
        return
    }
    
    # Create output file with headers
    "Domain,Nameserver,MX,SPF,DMARC" | Out-File -FilePath $OutputPath -Encoding utf8
    
    # Read CSV file
    $csvContent = Import-Csv -Path $CsvPath
    
    # Check if CSV has content
    if ($csvContent -eq $null) {
        Write-Host "CSV file is empty"
        return
    }
    
    # Get first property name
    $firstProperty = $null
    $properties = Get-Member -InputObject $csvContent[0] -MemberType NoteProperty
    if ($properties -ne $null -and $properties.Length -gt 0) {
        $firstProperty = $properties[0].Name
    }
    
    if ($firstProperty -eq $null) {
        Write-Host "Could not determine column name in CSV file"
        return
    }
    
    # Count total domains for progress
    $totalRows = 0
    foreach ($row in $csvContent) { $totalRows++ }
    
    # Process each domain
    $currentRow = 0
    foreach ($row in $csvContent) {
        $currentRow++
        $domain = $row.$firstProperty
        
        # Skip empty domains
        if ([string]::IsNullOrEmpty($domain)) {
            Write-Host "Skipping empty domain at row $currentRow"
            continue
        }
        
        # Show progress
        Write-Progress -Activity "Processing DNS Records" -Status "Domain: $domain" -PercentComplete (($currentRow / $totalRows) * 100)
        Write-Host "Processing domain: $domain"
        
        # Convert domain to Punycode if needed
        $lookupDomain = ConvertTo-Punycode -Domain $domain
        
        # Get DNS records
        $nameserver = Get-NameserverRecords -Domain $lookupDomain
        $mx = Get-MXRecords -Domain $lookupDomain
        $spf = Get-SPFRecord -Domain $lookupDomain
        $dmarc = Get-DMARCRecord -Domain $lookupDomain
        
        # Escape commas in CSV values
        $nameserver = $nameserver -replace ',', ';'
        $mx = $mx -replace ',', ';'
        $spf = $spf -replace ',', ';'
        $dmarc = $dmarc -replace ',', ';'
        
        # Write to CSV
        "$domain,$nameserver,$mx,$spf,$dmarc" | Out-File -FilePath $OutputPath -Encoding utf8 -Append
    }
    
    Write-Host "Process completed. Results exported to: $OutputPath"
}

# Get the script directory
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path

# Display welcome message
Write-Host "========================================"
Write-Host "DNS CHECKER - Domain DNS Record Analysis"
Write-Host "========================================"
Write-Host "Dieses Skript analysiert Domains aus einer CSV-Datei und exportiert DNS-Informationen."
Write-Host ""

# Get input CSV path from user
$csvPath = Read-Host "Geben Sie den Pfad zur CSV-Datei mit den Domains ein"

# Generate output path in the same directory as the script
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$outputFileName = "DomainDnsResults_$timestamp.csv"
$outputPath = Join-Path -Path $scriptPath -ChildPath $outputFileName

# Run the DNS check
Write-Host "Starte Analyse..."
Start-DNSCheck -CsvPath $csvPath -OutputPath $outputPath

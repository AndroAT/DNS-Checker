# DNS Checker Script
# This script reads domains from a CSV file, performs DNS lookups, and exports results to CSV

# Set error action preference
$ErrorActionPreference = "SilentlyContinue"

# Function to check if domain exists
function Test-DomainExists {
    param (
        [string]$Domain
    )
   
    
    try {
        # Try to resolve any DNS record for the domain
        $anyRecord = Resolve-DnsName -Name $Domain -Type A -ErrorAction SilentlyContinue
        if ($anyRecord -eq $null) {
            $anyRecord = Resolve-DnsName -Name $Domain -Type NS -ErrorAction SilentlyContinue
        }
        
        return ($anyRecord -ne $null)
    }
    catch {
        return $false
    }
}

# Function to get nameserver records
function Get-NameserverRecords {
    param (
        [string]$Domain,
        [bool]$DomainExists
    )
    
    if (-not $DomainExists) {
        return "n/a"
    }
    
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
        [string]$Domain,
        [bool]$DomainExists
    )
    
    if (-not $DomainExists) {
        return "n/a"
    }
    
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
        [string]$Domain,
        [bool]$DomainExists
    )
    
    if (-not $DomainExists) {
        return "n/a"
    }
    
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
        [string]$Domain,
        [bool]$DomainExists
    )
    
    if (-not $DomainExists) {
        return "n/a"
    }
    
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
    
    # Read CSV file with UTF-8 encoding
    $csvContent = Import-Csv -Path $CsvPath -Encoding UTF8
    
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
        
        # Check if domain exists
        $domainExists = Test-DomainExists -Domain $domain
        if (-not $domainExists) {
            Write-Host "Domain existiert nicht: $domain" -ForegroundColor Yellow
            # Write n/a for all fields for non-existent domains
            "$domain,n/a,n/a,n/a,n/a" | Out-File -FilePath $OutputPath -Encoding utf8 -Append
            continue
        }
        
        # Get DNS records
        $nameserver = Get-NameserverRecords -Domain $domain -DomainExists $domainExists
        $mx = Get-MXRecords -Domain $domain -DomainExists $domainExists
        $spf = Get-SPFRecord -Domain $domain -DomainExists $domainExists
        $dmarc = Get-DMARCRecord -Domain $domain -DomainExists $domainExists
        
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

# Set input and output paths
$csvPath = Join-Path -Path $scriptPath -ChildPath "domains.csv"
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$outputFileName = "DomainDnsResults_$timestamp.csv"
$outputPath = Join-Path -Path $scriptPath -ChildPath $outputFileName

# Display welcome message
Write-Host "========================================"
Write-Host "DNS CHECKER - Domain DNS Record Analysis"
Write-Host "========================================"
Write-Host "Dieses Skript analysiert Domains aus domains.csv und exportiert DNS-Informationen."
Write-Host "Input: $csvPath"
Write-Host "Output: $outputPath"
Write-Host ""

# Check if domains.csv exists
if (-not (Test-Path $csvPath)) {
    Write-Host "FEHLER: domains.csv wurde nicht im Skriptverzeichnis gefunden!" -ForegroundColor Red
    Write-Host "Bitte erstellen Sie eine CSV-Datei mit Domainnamen im Skriptverzeichnis." -ForegroundColor Red
    exit
}

# Run the DNS check
Write-Host "Starte Analyse..."
Start-DNSCheck -CsvPath $csvPath -OutputPath $outputPath

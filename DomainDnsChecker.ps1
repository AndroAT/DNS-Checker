# DNS Checker Script
# This script reads domains from a CSV file, performs DNS lookups, and exports results to CSV

# Function to convert IDN (Internationalized Domain Name) to Punycode
function ConvertTo-Punycode {
    param (
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
        $punycodeResult = [String]::Join(".", $punyParts)
        return $punycodeResult
    }
    catch {
        Write-Warning "Could not convert domain to Punycode: $Domain. Error: $_"
        return $Domain # Return original if conversion fails
    }
}

# Function to create a simple custom object (compatible with all PowerShell versions)
function New-SimpleObject {
    $obj = New-Object -TypeName System.Object
    
    # Add Domain property
    $objDomain = New-Object -TypeName System.Management.Automation.PSNoteProperty
    $objDomain.Name = "Domain"
    $objDomain.Value = $args[0]
    $obj.psobject.Properties.Add($objDomain)
    
    # Add Nameserver property
    $objNS = New-Object -TypeName System.Management.Automation.PSNoteProperty
    $objNS.Name = "Nameserver"
    $objNS.Value = "none"
    $obj.psobject.Properties.Add($objNS)
    
    # Add MX property
    $objMX = New-Object -TypeName System.Management.Automation.PSNoteProperty
    $objMX.Name = "MX"
    $objMX.Value = "none"
    $obj.psobject.Properties.Add($objMX)
    
    # Add SPF property
    $objSPF = New-Object -TypeName System.Management.Automation.PSNoteProperty
    $objSPF.Name = "SPF"
    $objSPF.Value = "none"
    $obj.psobject.Properties.Add($objSPF)
    
    # Add DMARC property
    $objDMARC = New-Object -TypeName System.Management.Automation.PSNoteProperty
    $objDMARC.Name = "DMARC"
    $objDMARC.Value = "none"
    $obj.psobject.Properties.Add($objDMARC)
    
    return $obj
}

# Safely get DNS records
function Get-SafeDnsRecords {
    param (
        [string]$Domain,
        [string]$RecordType
    )
    
    $result = @()
    
    try {
        $result = Resolve-DnsName -Name $Domain -Type $RecordType -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "Error resolving $RecordType records for $Domain : $_"
    }
    
    return $result
}

# Function to get DNS records for a domain
function Get-DomainDnsRecords {
    param (
        [string]$Domain
    )
    
    # Create a simple object
    $result = New-SimpleObject $Domain
    
    try {
        # Convert domain to Punycode if it contains non-ASCII characters
        $lookupDomain = ConvertTo-Punycode -Domain $Domain
        
        # Get NS (Nameserver) records
        $nsRecords = Get-SafeDnsRecords -Domain $lookupDomain -RecordType "NS"
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
        $mxRecords = Get-SafeDnsRecords -Domain $lookupDomain -RecordType "MX"
        if ($mxRecords) {
            $mxValues = @()
            foreach ($record in $mxRecords) {
                if ($record.NameExchange -and $record.Preference) {
                    $mxValues += "$($record.NameExchange) (Preference: $($record.Preference))"
                }
            }
            if ($mxValues.Count -gt 0) {
                $result.MX = [string]::Join(", ", $mxValues)
            }
        }
        
        # Get SPF records (stored as TXT)
        $txtRecords = Get-SafeDnsRecords -Domain $lookupDomain -RecordType "TXT"
        if ($txtRecords) {
            foreach ($record in $txtRecords) {
                if ($record.Strings) {
                    $txtValue = [string]::Join(" ", $record.Strings)
                    if ($txtValue -match "v=spf1") {
                        $result.SPF = $txtValue
                        break
                    }
                }
            }
        }
        
        # Get DMARC records (stored as TXT at _dmarc subdomain)
        $dmarcDomain = "_dmarc.$lookupDomain"
        $dmarcRecords = Get-SafeDnsRecords -Domain $dmarcDomain -RecordType "TXT"
        if ($dmarcRecords) {
            foreach ($record in $dmarcRecords) {
                if ($record.Strings) {
                    $dmarcValue = [string]::Join(" ", $record.Strings)
                    if ($dmarcValue -match "v=DMARC1") {
                        $result.DMARC = $dmarcValue
                        break
                    }
                }
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
        [string]$CsvPath,
        [string]$OutputPath
    )
    
    # Check if CSV file exists
    if (-not (Test-Path $CsvPath)) {
        Write-Error "CSV file not found at path: $CsvPath"
        return
    }
    
    # Import domains from CSV
    try {
        $csvContent = Import-Csv -Path $CsvPath
        
        # Check if the CSV has any rows
        if (-not $csvContent) {
            Write-Error "CSV file does not contain any data"
            return
        }
        
        # Get the first property name (column)
        $firstRow = $csvContent[0]
        $firstProperty = $null
        foreach ($property in $firstRow.PSObject.Properties) {
            $firstProperty = $property.Name
            break
        }
        
        if (-not $firstProperty) {
            Write-Error "Could not determine column name in CSV file"
            return
        }
        
        # Initialize results array
        $results = @()
        
        # Process each domain
        $totalRows = 0
        foreach ($row in $csvContent) { $totalRows++ }
        $currentRow = 0
        
        foreach ($row in $csvContent) {
            $currentRow++
            $domain = $row.$firstProperty
            
            # Skip empty domains
            if ([string]::IsNullOrEmpty($domain) -or $domain.Trim() -eq "") {
                Write-Warning "Skipping empty domain at row $currentRow"
                continue
            }
            
            Write-Progress -Activity "Processing DNS Records" -Status "Domain: $domain" -PercentComplete (($currentRow / $totalRows) * 100)
            
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

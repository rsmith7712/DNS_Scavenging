﻿<#	
	.NOTES
	===========================================================================
	 Created with: 	SAPIEN Technologies, Inc., PowerShell Studio 2016 v5.2.127
	 Created on:   	9/26/2016 9:40 AM
	 Created by:   	Mr. Hiraldo - Tips4teks.blogspot.com.
	 Modified by: 	Richard Smith
	 Organization: 	
	 Filename:     	git-DNS_Scavenging.ps1
	===========================================================================
	.DESCRIPTION
		Powershell script that will get the stale records from the zone and match 
		them with the computer object in AD. Then use, the OperatingSystem field 
		value of that computer object to decide whether you would delete the A record 
		or not. In the end, you can have the script send you an email with the 
		report so you can have a Windows scheduled task do that for you every 
		Saturday or so!
#>

Import-Module activedirectory

$DnsServer = (Get-ADDomain -Identity Savers.com).ReplicaDirectoryServers[0];

#Change value DeletingEnabled to $true if you want to delete the Stale DNS Records
# $DeletingEnabled = $true
$DeletingEnabled = $false
Function DeleteDNSRecord($Record)
{
	$Owner = $Record.OwnerName
	$IPAddress = $Record.IPAddress
	
	Write-host "Deleting $Owner $IPAddress"
	Get-WmiObject -Computer $ServerName -Namespace "root\MicrosoftDNS" -Class "MicrosoftDNS_AType" -Filter "IPAddress = '$IPAddress' AND OwnerName = '$Owner'" | Remove-WmiObject
	if ($?)
	{
		return "Yes"
	}
	else
	{
		return "No"
	}
}

#The variable Pathdir is used for logging later. Configure to whatever folder you'd like.
$Pathdir = "C:\"
$reportObject = @()
$NotInAD = @()
$TotalAgingInterval = 14 #It will delete records older than what specified here.
$Date = get-date -format 'yyyy.MM.dd'
$ServerName = "DOMAIN_CONTROLLER.DOMAIN.com" #Choose your DNS server here.
# $ServerName = (GET-ADDOMAIN -Identity Savers.com).ReplicadirectoryServers
$ContainerName = "DOMAIN.com"
$DomainZone = "DomainDNSZones." + $ContainerName

$MinTimeStamp = [Int](New-TimeSpan `
								   -Start $(Get-Date("01/01/1601 00:00")) `
								   -End $((Get-Date).AddDays(- $TotalAgingInterval))).TotalHours
Write-Host "Gathering DNS A Records... Please wait" -ForegroundColor Yellow
Get-WMIObject -Computer $ServerName `
			  -Namespace "root\MicrosoftDNS" -Class "MicrosoftDNS_AType" `
			  -Filter `
			  "ContainerName='$ContainerName' AND TimeStamp<$MinTimeStamp AND TimeStamp<>0" `
| Select-Object OwnerName, `
				@{ n = "TimeStamp"; e = { (Get-Date("01/01/1601")).AddHours($_.TimeStamp) } }, IPAddress, TTL | Export-csv -path "$Pathdir\AllStaleDNSRecords.csv"
Write-Host "Gathering DNS A Records completed!" -ForegroundColor Green
Write-Host "Searching DNS A Records in AD... Please wait" -ForegroundColor Yellow
$DNSRecords = Import-Csv -Path "$Pathdir\AllStaleDNSRecords.csv"
foreach ($Record in $DNSRecords)
{
	if (($Record.OwnerName -ne $ContainerName) -and ($Record.OwnerName -ne $DomainZone))
	{
		$hostname = $Record.OwnerName
		$IPAddress = $Record.IPAddress
		$ADObject = Get-ADComputer -filter { (DNSHostName -like $hostname) } -Properties OperatingSystem, DistinguishedName
		if ($ADObject -ne $null)
		{
			if (($ADObject.OperatingSystem -ne $null) -and (($ADObject.Operatingsystem -like "*Windows XP*") -or ($ADObject.OperatingSystem -like "*Windows 7*") -or ($ADObject.OperatingSystem -like "*Windows 8*") -or ($ADObject.OperatingSystem -like "Mac OS X")))
			{
				$output = "" | Select DNSOwnerName, ADName, OperatingSystem, IPAddress, TTL, TimeStamp, Deleted, DistinguishedName
				$output.DNSOwnerName = $hostname
				$output.ADName = $ADObject.Name
				$output.OperatingSystem = $ADObject.OperatingSystem
				$output.IPAddress = $IPAddress
				$output.TTL = $Record.TTL
				$output.TimeStamp = $Record.TimeStamp
				$output.DistinguishedName = $ADObject.DistinguishedName
				if ($DeletingEnabled -eq $true)
				{
					$output.Deleted = DeleteDNSRecord($Record)
				}
				else
				{
					$output.Deleted = "Deleting Not Enabled"
				}
				
				$reportObject += $output
				
			}
			
			
		}
		else
		{
			Write-Host "Record doesn't exist in AD and will be deleted." $hostname
			$Erroutput = "" | Select DNSOwnerName, IPAddress, TTL, TimeStamp, Deleted
			$Erroutput.DNSOwnerName = $Record.OwnerName
			$Erroutput.IPAddress = $Record.IPAddress
			$Erroutput.TTL = $Record.TTL
			$Erroutput.TimeStamp = $Record.TimeStamp
			if ($DeletingEnabled -eq $true)
			{
				$Erroutput.Deleted = DeleteDNSRecord($Record)
			}
			else
			{
				$Erroutput.Deleted = "Deleting Not Enabled"
			}
			
			$NotInAD += $Erroutput
		}
		
	}
	
}
Write-Host "Scavenging Maintenance Complete! Exporting to CSV.." -ForegroundColor Green
$reportObject | Export-csv -path "$Pathdir\DNSRecords-to-delete-with-ADinfo-$Date.csv"
$NotInAD | Export-csv -path "$Pathdir\DNSRecords-NotInAD-Deleted-$Date.csv"

$to = "EMAIL ADDRESS"
$Subject = "DNS Scavenging Report for $Date"
$Body = "Hello Team,`nThe following reports attached show the DNS records scanvenged from zone $ContainerName"
$Relay = "SMTP SERVER"
$From = "EMAIL ADDRESS"
$Attach = "$Pathdir\DNSRecords-to-delete-with-ADinfo-$Date.csv", "$Pathdir\DNSRecords-NotInAD-Deleted-$Date.csv"
#Send the Email and attachment
Send-MailMessage -to $to -Subject $Subject -Body $Body -SmtpServer $Relay -Attachments $Attach -From $From
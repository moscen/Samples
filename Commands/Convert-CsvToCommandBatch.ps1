﻿<#
.SYNOPSIS
	Creates a command batch from a CSV file as the data source for the command parameters.
.DESCRIPTION
	This script can be used to convert command batches from CSV to XML. 
	The input data file can contain the name of the command to carry out for each CSV record in
	the column named CommandName, but this is not neccessary. The script parameter -defaultCommandName
	can be used if the data source only contains data and no command names.
	
	Each column, except for CommandName, is mapped to command parameters. However, the parameter can
	be overridden in the file by specifying the target parameter name in square brackets - for example:
	
	Titel [Title],Benämning [Description],Annat []
	
	Note: Using an empty set of brackets ignores the column.
	
	If the source file can't be modified for column to parameter name mapping there are some 
	script parameters available to accomplish the same thing;
	-columnToParameterMap is specificed as a hash table and -ignoredColumns is a string array. 
	The column to parameter name mapping example above can be accomplished using the following:
	-columnToParameterMap @{ "Titel" = "Title"; "Benämning" = "Description" } 
	-ignoredColumns "Annat"

	Multiple target parameters is supported by separating the target parameter names with comma:

	ProduktNr [UnitId|Code]
	
	- or, the command line argument -
	
	-columnToParameterMap @{ "ProduktNr" = "UnitId|Code" } 
	
	If the file comes from Excel it may be saved using ASCII or UTF7 encoding. To convert the 
	data source from that encoding to UTF8 the following parameter can be used:
	-reencodeFromEncoding UTF7
	
	To preview the specified column to parameter name mapping without actually creating 
	an XML file, use the -preview switch.
.PARAMETER csvFile
	The path of the CSV file
.PARAMETER outputFile
	The path to the XML file to be created
.PARAMETER defaultCommandName
	The command name to be used for each CSV record if not specified in the CommandName column
.PARAMETER filter
	A row filter to apply to the source file before processing any rows
.PARAMETER columnToParameterMap
	A hashtable defining mappings of source column to destination parameter(s)
.PARAMETER ignoredColumns
	A list of colums to skip when mapping CSV columns to command parameters
.PARAMETER columnValuePrefix
	A hashtable defining mappings of column to parameter value prefixes to be applied to the source data.
	Pro tip: Can be used to add prefixes like "System.Picklist.Unit.Types." to data that needs to be a localization keyword.
.PARAMETER reencodeFromEncoding
	If present, source encoding for the source file. Pro tip: Specify UTF7 if source file is generated by Excel. 
.PARAMETER preview
	Only prints the CSV column to command parameter mapping and does not produce the output file.
#>
param( 
	[parameter(mandatory=$true, valuefrompipeline=$true)]
	$csvFile,
	[parameter(mandatory=$true)]
	$outputFile,
	[parameter(mandatory=$false)]
	$defaultCommandName = "",
	[parameter(mandatory=$false)]
	[scriptblock] $filter = { $true },
	[parameter(mandatory=$false)]
	[hashtable]$columnToParameterMap,
	[parameter(mandatory=$false)]
	[string[]]$ignoredColumns,
	[parameter(mandatory=$false)]
	[hashtable]$columnValuePrefix,
	[parameter(mandatory=$false)]
	[Microsoft.PowerShell.Commands.FileSystemCmdletProviderEncoding] $reencodeFromEncoding,
	[parameter(mandatory=$false)]
	[Switch] $preview
)

$dataFile = $csvFile
if( $reencodeFromEncoding ) {
	$dataFile = [System.IO.Path]::GetTempFileName()
	gc $csvFile -Encoding $reencodeFromEncoding | Out-File -Encoding UTF8 -FilePath $dataFile
}
$data = Import-Csv $dataFile
$recordCount = ($data | measure).Count
Write-Host "Found $recordCount records"

if(!$columnToParameterMap) { $columnToParameterMap = @{} }
if(!$ignoredColumns) { $ignoredColumns = @() }
if(!$columnValuePrefix) { $columnValuePrefix = @{} }

$xmlns = "http://schemas.remotex.net/Apps/201207/Commands"
$CommandBatch = [xml]@"
<?xml version="1.0" encoding="utf-8"?>
<CommandBatch xmlns="$xmlns" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
</CommandBatch>
"@

$attrs = $data | Select -first 1 | gm -MemberType NoteProperty | ?{ $_.Name -ne "CommandName" } | Select -ExpandProperty Name

function getParameterNameForColumn( $columnName ) {
	$columnName = $columnName.Trim()
	if( $ignoredColumns -contains $columnName ) {
		""
	} elseif( $columnToParameterMap.ContainsKey( $columnName ) ) {
		$columnToParameterMap[$columnName]
	} elseif( $columnName -match "(?<=\[)[^\]]*(?=\])" ) {
		$matches[0]
	} else {
		$columnName
	}
}
function getParameterValueForColumn( $columnName, $value ) {
	$columnName = $columnName.Trim()
	if( $columnValuePrefix.ContainsKey( $columnName ) ) {
		[string]::Concat( $columnValuePrefix[$columnName], $value )
	} else {
		$value
	}
}

$parameterMap = $attrs | select @{Name="Column";Expression={ $_ }},@{Name="Parameter";Expression={ getParameterNameForColumn $_ }}
Write-Host "Parameter map:"
$parameterMap | ?{ $_.Parameter } | %{
	Write-Host ("  {0} => {1}" -f $_.Column, $_.Parameter)
}
Write-Host "Ignored columns:"
( $ignoredColumns + ( $attrs | ?{ $_ -match "\[\]" } ) ) | select -Unique | %{
	$ignoredColumn = $_.Trim()
	Write-Host "  $ignoredColumn"
}
Write-Host ""

if($preview) {
	return
}

$filteredRecords = $data | ?{ [scriptblock]::Create($filter.ToString().Replace( "$_", "$args[0]") ).InvokeReturnAsIs($_) }
$filteredRecordCount = ($filteredRecords | measure).Count
if( $filteredRecordCount -ne $recordCount ) {
	Write-Host "Filtered out $filteredRecordCount records matching $($filter.ToString())"
}
foreach ($record in $filteredRecords ){
    $Command = $CommandBatch.CreateElement("Command", $xmlns)
    $Command.AppendChild($CommandBatch.CreateElement("Name", $xmlns)) | out-null
	if( $record.CommandName ) {
    	$Command.Name = $record.CommandName.ToString()
	} else {
		$Command.Name = $defaultCommandName
	}
    
    foreach ($attr in $attrs){
        $val = $record."$attr"
        if($val){
			(getParameterNameForColumn ($attr.ToString())).Split("|") | %{
	            $Parameter = $CommandBatch.CreateElement("Parameter", $xmlns)
	            $Parameter.AppendChild($CommandBatch.CreateElement("Name", $xmlns)) | out-null
	            $Parameter.Name = $_.ToString()
	            $Parameter.AppendChild($CommandBatch.CreateElement("Value", $xmlns)) | out-null
	            $Parameter.Value = (getParameterValueForColumn $_ $val.ToString().Trim()).Trim()
	            $Command.AppendChild($Parameter) | Out-Null
			}
        }
    }
    $CommandBatch.CommandBatch.AppendChild($Command) | out-null
}

if( ![System.IO.Path]::IsPathRooted( $outputFile ) ) {
	$outputFile = Join-Path $PWD $outputFile
}
$CommandBatch.Save( $outputFile )
#Region ;**** Directives created by AutoIt3Wrapper_GUI ****
#AutoIt3Wrapper_UseX64=n
#EndRegion ;**** Directives created by AutoIt3Wrapper_GUI ****

; PROGRAM:  CUBEIT
; FUNCTION: BFB GCode (Kisslicer) post-processor for CubeX Compatibility

#include <GUIConstantsEx.au3>
#include <WindowsConstants.au3>
#include <StaticConstants.au3>
#include <EditConstants.au3>
#include <Array.au3>

Global $IniFile
Global $InputFile

Global $M55
Global $E1Key
Global $E2Key
Global $E3Key
Global $NozzleMaterials[4]
Global $Debug=0

Global $MaterialCount=0
Global $MaterialInfo[1][4]

Global $NozzleSwapCount=0
Global $NozzleSwapInfo[1][3]

Global $NUsage
Global $NSWaps
Global $NNewUsage
Global $NMaterials

Global $NNewUsageArray[4] = [4,0,0,0]

; Determine Local INI Config file name based on Name of the Script
$IniFile = StringTrimRight(@ScriptFullPath,4) & ".ini"

; Get General Config Settings from INI
GetConfig()

; Read/Populate the MaterialInfo Array from INI
GetMaterialInfo()

; Read/Populate the NozzleSwapInfo Array of Codes from INI
GetNozzleSwapInfo()

if $CmdLine[0] > 0 Then
	; If Input File is Provided in Command Line, then Process without GUI (as a Kisslicer Post-Processor)
	; Call as CUBEIT {InputFileName} [{Material Codes}]
	; Where {InputFileName} is the name of the file to process (will be saved as *.BAK)
	;       {MaterialCodes} is used to override the Material Codes in the INI file [optional]
	;                       it is a comma delimited list of Material ID's as configured in your printer, all three ID's must be provided, use a zero for "none"
	;                       For Example: With PLA Black in #1, PLA Red in #2, and #3 empty, the parameter would be "209,202,0"

	$InputFile = $CmdLine[1]

	If $CmdLine[0] > 1 Then
		$TempArray = StringSplit($CmdLine[2], ',')
		For $i = 1 to 3
			$NozzleMaterials[$i] = $TempArray[$i]
		Next
	EndIf

Else
	; Process Intercatively with GUI

	$InputFile = FileOpenDialog("CubeIt: Please Select an Input File", @WorkingDir, "BFB Files (*.BFB)|All Files (*.*)", 1)

EndIf

; Determine Nozzles Used in the original File
$NUsage = GetNozzleUsage($InputFile)

; Get Nozzle Swap Info from User (Only ifInteractive)
If $CmdLine[0] = 0 Then
	$NSwaps = GetNozzleSwaps($NUsage)
Else
	$NSwaps = "0,0,0"
EndIf

; Convert Nozzle Usage String to an Array
Global $NUsageArray = StringSplit($NUsage, ',')

; Convert Nozzle Swap String to an Array
Global $NSwapArray = StringSplit($NSwaps, ',')

; Calculate the New Nozzle Usage Array (with Swaps applied)
For $i = 1 to 3
	If $NUsageArray[$i] = 1 Then
		If ($NSwapArray[$i] = 0) or ($NSwapArray[$i] = $i) Then
			$NNewUsageArray[$i] = 1
		Else
			$NNewUsageArray[$NSwapArray[$i]] = 1
		EndIf
	EndIf
Next

; Generate New Nozzle Usage Strings and Nozzle Material Strings back from their respective arrays (Mostly for Debug Info)
$NNewUsage=""
$NMaterials=""
For $i = 1 to 3
	$NNewUsage &= $NNewUsageArray[$i] & ","
	$NMaterials &= $NozzleMaterials[$i] & ","
Next
$NNewUsage=StringTrimRight($NNewUsage,1)
$NMaterials=StringTrimRight($NMaterials,1)

; Display Debug info if set in INI
if $Debug=1 Then
	_ArrayDisplay($MaterialInfo,"DEBUG: MaterialInfo")
	_ArrayDisplay($NozzleSwapInfo,"DEBUG: NozzleSwapInfo")
	MsgBox(0,"DEBUG: NUsage (N1, N2, N3)",$NUsage)
	MsgBox(0,"DEBUG: NSwaps (N1, N2, N3)",$NSwaps)
	MsgBox(0,"DEBUG: NNewUsage (N1, N2, N3)",$NNewUsage)
	MsgBox(0,"DEBUG: NMaterials (N1, N2, N3)",$NMaterials)
	if MsgBox(1,"DEBUG: Continue?","OK to Continue / CANCEL to Quit") = 2 Then Exit
EndIf

; Warn if Nozzle Swaps Requested
If $NSwaps <> "0,0,0" Then
	If MsgBox(1,"CubeIt: Warning!", _
		"It appears you have requested one of more Nozzle Swaps." & @LF & @LF & _
		"CubeIt DOES NOT make any adjustments to accomodate Material Changes.  " & _
		"Please ensure you have the same material loaded in the target nozzle " & _
		"as was originally expected in the source print file.  " & @LF & @LF & _
		"Press OK to continue, or CANCEL to abort") _
	= 2 Then Exit
EndIf

; Here we go!
ProcessFile()

; Done!
If $CmdLine[0] = 0 Then MsgBox(0,"CubeIt Completed!","New File:  " & $InputFile & @CRLF & @CRLF & "Original File:  " & $InputFile & ".bak")

Exit

;--------------------------------------------------------------------------------------------------

Func ProcessFile()

	FileMove($InputFile, $InputFile & ".bak", 1)

	$hInput = FileOpen($InputFile & ".bak")
	$hOutput = FileOpen($InputFile, 2)

	; Write Header
	WriteFileHeader($hOutput)
	For $i = 1 to 3
		If $NNewUsageArray[$i] Then FileWriteLine($hOutput, "^MaterialLengthE" & $i & ": 1")
	Next
	For $i = 1 to 3
		If $NNewUsageArray[$i] Then FileWriteLine($hOutput, "^MaterialCodeE" & $i & ": " & $NozzleMaterials[$i])
	Next

	; Process the Input File Line by Line
	While 1
		$line = FileReadLine($hInput)
		If @error = -1 Then ExitLoop

		; Eliminate Blank Lines
		If $line = "" Then ContinueLoop

		; Eliminate Comments
		If StringLeft($line, 1) = ";" Then ContinueLoop

		; Eliminate Old CubeX Header Data (Allows ReProcessing a File)
		If StringLeft($line, 1) = "^" Then ContinueLoop

		; Update Extruder Priming Commands
		If StringLeft($line, 3) = "M55" Then $line = StringLeft($line,5) & $M55

		; Process Nozzle Swaps (if requested)
		If $NSwaps <> "0,0,0" Then
			For $i = 1 to 3
				if $NSwapArray[$i] <> "0" Then
					$newline = NozzleSwap($line, $i, $NSwapArray[$i])
					if $newline <> $line then
						$line = $newline
						ExitLoop
					EndIf
				EndIf
			Next
		EndIf

		; Write the processed Line
		FileWriteLine($hOutput, $line)
	WEnd

	FileClose($hInput)
	FileClose($hOutput)

EndFunc

Func WriteFileHeader($hOutput)

	$SectionArray = IniReadSection($IniFile, "Header")
	If @error Then
		MsgBox(0, "Error!", $IniFile & " Missing or [Header] Section not present")
	    Exit
	EndIf

	; Write Header Lines in order they appear in the [HEADER] section of the INI file
	For $i = 1 To $SectionArray[0][0]
		FileWriteLine($hOutput, $SectionArray[$i][1])
	Next

	Return $SectionArray[0][0]

EndFunc

Func NozzleSwap($line, $OldNozz, $NewNozz)

	If $NewNozz = 0 Then Return $line

	For $i = 0 to $NozzleSwapCount-1
		If StringLeft($line, StringLen($NozzleSwapInfo[$i][$OldNozz - 1])) = $NozzleSwapInfo[$i][$OldNozz -1] Then
			$line = $NozzleSwapInfo[$i][$NewNozz - 1] & StringTrimLeft($line, StringLen($NozzleSwapInfo[$i][$OldNozz - 1]))
		EndIf
	Next

	Return $line

EndFunc

Func GetNozzleSwaps($NUsage)

	GUICreate("CubeIt: Processing Info", 300, 365, -1, -1, $WS_SIZEBOX)

	; Printer Configuration

	GUICtrlCreateGroup("CubeX Printer Configuration", 10, 10, 280, 115)

	$E1Info = "Extruder 1: " & DecodeMaterial($NozzleMaterials[1])
	$E1Label = GUICtrlCreateLabel($E1Info, 20, 35, 180)
	$E1Button = GUICtrlCreateButton("Change", 205, 30, 70)

	$E2Info = "Extruder 2: " & DecodeMaterial($NozzleMaterials[2])
	$E2Label = GUICtrlCreateLabel($E2Info, 20, 65, 180)
	$E2Button = GUICtrlCreateButton("Change", 205, 60, 70)

	$E3Info = "Extruder 3: " & DecodeMaterial($NozzleMaterials[3])
	$E3Label = GUICtrlCreateLabel($E3Info, 20, 95, 180)
	$E3Button = GUICtrlCreateButton("Change", 205, 90, 70)

	; Nozzle Swaps

	GUICtrlCreateGroup("Extruder Swaps", 10, 130, 280, 155)

    GUIStartGroup()
	$N1Label = GUICtrlCreateLabel("Extruder 1", 20, 155, 100)
    $E1Swap1 = GUICtrlCreateRadio("Ext1", 135, 152, 50, 20)
    $E1Swap2 = GUICtrlCreateRadio("Ext2", 185, 152, 50, 20)
    $E1Swap3 = GUICtrlCreateRadio("Ext3", 235, 152, 50, 20)
	GUICtrlSetState($E1Swap1, $GUI_CHECKED)

    GUIStartGroup()
	$N2Label = GUICtrlCreateLabel("Extruder 2", 20, 185, 100)
    $E2Swap1 = GUICtrlCreateRadio("Ext1", 135, 182, 50, 20)
    $E2Swap2 = GUICtrlCreateRadio("Ext2", 185, 182, 50, 20)
    $E2Swap3 = GUICtrlCreateRadio("Ext3", 235, 182, 50, 20)
	GUICtrlSetState($E2Swap2, $GUI_CHECKED)

    GUIStartGroup()
	$N3Label = GUICtrlCreateLabel("Extruder 3", 20, 215, 100)
    $E3Swap1 = GUICtrlCreateRadio("Ext1", 135, 212, 50, 20)
    $E3Swap2 = GUICtrlCreateRadio("Ext2", 185, 212, 50, 20)
    $E3Swap3 = GUICtrlCreateRadio("Ext3", 235, 212, 50, 20)
	GUICtrlSetState($E3Swap3, $GUI_CHECKED)

	GUICtrlCreateLabel("(Only extruders actually used in your", 10, 245, 260, -1, $SS_CENTER)
	GUICtrlCreateLabel("original print file will be swappable)", 10, 260, 260, -1, $SS_CENTER)

	; Program Control

	$OKButton = GUICtrlCreateButton("OK", 20, 300, 70)
	$CancelButton = GUICtrlCreateButton("Cancel", 200, 300, 70)

	; Disable Controls for Unused Extruders

	$NUsageArray=StringSplit($NUsage, ',')
	If $NUsageArray[1] = "0" Then
		GUICtrlSetState($N1Label, $GUI_Disable)
		GUICtrlSetState($E1Swap1, $GUI_Disable)
		GUICtrlSetState($E1Swap2, $GUI_Disable)
		GUICtrlSetState($E1Swap3, $GUI_Disable)
	EndIf
	If $NUsageArray[2] = "0" Then
		GUICtrlSetState($N2Label, $GUI_Disable)
		GUICtrlSetState($E2Swap1, $GUI_Disable)
		GUICtrlSetState($E2Swap2, $GUI_Disable)
		GUICtrlSetState($E2Swap3, $GUI_Disable)
	EndIf
	If $NUsageArray[3] = "0" Then
		GUICtrlSetState($N3Label, $GUI_Disable)
		GUICtrlSetState($E3Swap1, $GUI_Disable)
		GUICtrlSetState($E3Swap2, $GUI_Disable)
		GUICtrlSetState($E3Swap3, $GUI_Disable)
	EndIf

	GUISetState()

	While 1
		$msg = GUIGetMsg()
		Switch $msg
			Case $E1Button
				$NewMaterial=SelectMaterial()
				$E1Info = "Extruder 1: " & DecodeMaterial($NewMaterial)
				IniWrite($IniFile, "Config", "E1Material", $NewMaterial)
				$NozzleMaterials[1]=$NewMaterial
				GUICtrlSetData($E1Label,$E1Info)
			Case $E2Button
				$NewMaterial=SelectMaterial()
				$E2Info = "Extruder 2: " & DecodeMaterial($NewMaterial)
				IniWrite($IniFile, "Config", "E2Material", $NewMaterial)
				$NozzleMaterials[2]=$NewMaterial
				GUICtrlSetData($E2Label,$E2Info)
			Case $E3Button
				$NewMaterial=SelectMaterial()
				$E3Info = "Extruder 3: " & DecodeMaterial($NewMaterial)
				IniWrite($IniFile, "Config", "E3Material", $NewMaterial)
				$NozzleMaterials[3]=$NewMaterial
				GUICtrlSetData($E3Label,$E3Info)
			Case $GUI_EVENT_CLOSE
				GUIDelete()
				Exit
			Case $CancelButton
				GUIDelete()
				Exit
			Case $OKButton
				ExitLoop
		EndSwitch
	WEnd

	Select
		Case BitAND(GUICtrlRead($E1Swap2), $GUI_CHECKED) = $GUI_CHECKED
			$SwapInfo = "2,"
		Case BitAND(GUICtrlRead($E1Swap3), $GUI_CHECKED) = $GUI_CHECKED
			$SwapInfo = "3,"
		Case Else
			$SwapInfo = "0,"
	EndSelect

	Select
		Case BitAND(GUICtrlRead($E2Swap1), $GUI_CHECKED) = $GUI_CHECKED
			$SwapInfo &= "1,"
		Case BitAND(GUICtrlRead($E2Swap3), $GUI_CHECKED) = $GUI_CHECKED
			$SwapInfo &= "3,"
		Case Else
			$SwapInfo &= "0,"
	EndSelect

	Select
		Case BitAND(GUICtrlRead($E3Swap1), $GUI_CHECKED) = $GUI_CHECKED
			$SwapInfo &= "1"
		Case BitAND(GUICtrlRead($E3Swap2), $GUI_CHECKED) = $GUI_CHECKED
			$SwapInfo &= "2"
		Case Else
			$SwapInfo &= "0"
	EndSelect

	GUIDelete()

	return $SwapInfo
EndFunc

Func SelectMaterial()

	GUICreate("CubeIt: Please Select a Material", 500, 350, -1, -1, $WS_SIZEBOX)

	$listview = GUICtrlCreateListView(" Code | Material | Color ", 10, 10, 480, 275)
	$Cancel   = GUICtrlCreateButton("Exit", 225, 300, 50, 20)

	For $i = 0 To $MaterialCount-1
		$MaterialInfo[$i][3] = GUICtrlCreateListViewItem($MaterialInfo[$i][0] & " | " & $MaterialInfo[$i][1] & " | " & $MaterialInfo[$i][2], $listview)
	Next

	GUISetState()

	Do
		$msg = GUIGetMsg()

		For $i = 0 To $MaterialCount-1
			if $msg = $MaterialInfo[$i][3] then

				$MaterialCode = $MaterialInfo[$i][0]
				$Material = $MaterialInfo[$i][1]
				$Color = $MaterialInfo[$i][2]

				GUIDelete()
				return $MaterialCode

			EndIf
		Next

	Until $msg = $GUI_EVENT_CLOSE or $msg = $Cancel

	GUIDelete()
	return 0

EndFunc

Func DecodeMaterial($MaterialCode)
	For $i = 0 to $MaterialCount-1
		If $MaterialInfo[$i][0] = $MaterialCode Then
			Return $MaterialInfo[$i][1] & "," & $MaterialInfo[$i][2]
		EndIf
	Next

	Return "None,None"
EndFunc

Func GetConfig()
	If ((Not FileExists($IniFile)) AND ($CmdLine[0] = 0)) then
		MsgBox(0, "Error!", "Config File (" & $IniFile & ") Not Found!")
		Exit
	EndIf

	$M55 = IniRead($IniFile, "Config", "M55", "P1500 S150")
	$E1Key = IniRead($IniFile, "Config", "E1Key", "M101")
	$E2Key = IniRead($IniFile, "Config", "E2Key", "M201")
	$E3Key = IniRead($IniFile, "Config", "E3Key", "M301")
	$NozzleMaterials[1] = IniRead($IniFile, "Config", "E1Material", 0)
	$NozzleMaterials[2] = IniRead($IniFile, "Config", "E2Material", 0)
	$NozzleMaterials[3] = IniRead($IniFile, "Config", "E3Material", 0)
	$Debug = IniRead($IniFile, "Config", "Debug", 0)

EndFunc

Func GetMaterialInfo()

	$SectionArray = IniReadSection($IniFile, "MaterialInfo")
	If @error Then
		MsgBox(0, "Error!", $IniFile & " Missing or [MaterialInfo] Section not present")
		Exit
	EndIf

	$MaterialCount = $SectionArray[0][0]
	Global $MaterialInfo[$MaterialCount][4]

	For $i = 1 To $MaterialCount
		$MaterialData=StringSplit($SectionArray[$i][1], ',')
		$MaterialInfo[$i-1][0]=$SectionArray[$i][0]
		$MaterialInfo[$i-1][1]=$MaterialData[1]
		$MaterialInfo[$i-1][2]=$MaterialData[2]
	Next

	Return $MaterialCount
EndFunc

Func GetNozzleSwapInfo()

	$SectionArray = IniReadSection($IniFile, "NozzleSwapInfo")
	If @error Then
		MsgBox(0, "Error!", $IniFile & " Missing or [NozzleSwapInfo] Section not present")
		Exit
	EndIf

	$NozzleSwapCount = $SectionArray[0][0]
	Global $NozzleSwapInfo[$NozzleSwapCount][3]

	For $i = 1 To $NozzleSwapCount
		$DataSetArray=StringSplit($SectionArray[$i][1], ',')
		For $j = 0 to 2
			$NozzleSwapInfo[$i-1][$j]=$DataSetArray[$j+1]
		Next
	Next

	Return $NozzleSwapCount
EndFunc

Func GetNozzleUsage($InputFile)

	$E1Used=0
	$E2Used=0
	$E3Used=0

	$hInput = FileOpen($InputFile)

	While 1
		$line = FileReadLine($hInput)
		If @error = -1 Then ExitLoop

		Select
			Case StringLeft($line, StringLen($E1Key)) = $E1Key
				$E1Used=1
			Case StringLeft($line, StringLen($E2Key)) = $E2Key
				$E2Used=1
			Case StringLeft($line, StringLen($E3Key)) = $E3Key
				$E3Used=1
		EndSelect

	WEnd

	FileClose($hInput)

	Return $E1Used & "," & $E2Used  & "," & $E3Used
EndFunc

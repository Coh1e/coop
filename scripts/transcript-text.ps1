# Use the literal ESC character on both Windows PowerShell 5.1 and PowerShell 7.
function Format-TranscriptText([string]$text) {
    return $text.Replace([string][char]27,'<ESC>')
}

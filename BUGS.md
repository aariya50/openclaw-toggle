# Bug Fixes Needed

## 1. Info button closes menu dropdown
When clicking the Info/About menu item, the dropdown menu disappears. The About window should open while the menu closes gracefully.

## 2. Cmd+W doesn't close Preferences/About windows
macOS convention: Cmd+W should close the frontmost window. Currently Preferences and About/Info windows don't respond to Cmd+W. Need to add standard window key equivalents.

## 3. Preferences window UI polish
The Preferences window looks rough. Clean it up:
- Proper spacing, alignment, padding
- Native macOS look and feel (use system fonts, standard control sizes)
- Group related settings visually (sections with headers)
- Make it look like a real macOS preferences window

## 4. Check for Updates button in Preferences
- Add a "Check for Updates" button in Preferences
- Query GitHub Releases API to see if a newer version exists
- If update available, show version info and a button to update (run `brew upgrade openclaw-toggle`)
- Show "You're up to date" if on latest version

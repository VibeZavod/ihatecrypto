-- The DMG window the user opens (release.sh, on the read-write image): no toolbar, the background with its arrow,
-- the app on the left and Applications on the right, at the points make-background.py draws around.
on run argv
	set diskName to item 1 of argv
	tell application "Finder"
		tell disk diskName
			open
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			set pathbar visible of container window to false
			set the bounds of container window to {200, 120, 860, 548}
			set opts to the icon view options of container window
			set arrangement of opts to not arranged
			set icon size of opts to 112
			set text size of opts to 13
			set background picture of opts to file ".background:background.tiff"
			set position of item "ihatecrypto.app" of container window to {170, 170}
			set position of item "Applications" of container window to {490, 170}
			update without registering applications
			delay 2
			close
			-- Opened once more and sized again: Finder keeps the size it closes with, not the first one it was given.
			open
			set the bounds of container window to {200, 120, 860, 548}
			delay 2
			close
		end tell
	end tell
end run

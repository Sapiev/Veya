# Automation

Veya can be driven from AppleScript (PBI-605) and from Shortcuts and Siri (PBI-604).
Both run the same actions, and both wait up to 20 seconds for a signed-in session,
so a script can launch Veya and control it straight away.

## AppleScript

The dictionary (`Veya/Veya.sdef`, viewable in Script Editor > File > Open Dictionary)
uses the same terms and four-character codes as Spotify's, so most Spotify scripts
work after changing `"Spotify"` to `"Veya"`.

| Term | Kind | Notes |
|------|------|-------|
| `playpause` | command | Toggles play and pause. |
| `next track` | command | |
| `previous track` | command | |
| `play track <uri>` | command | Plays a track, album, playlist or other `spotify:` URI. Other text fails with error -10000. |
| `player state` | property | `stopped`, `playing` or `paused`. |
| `current track` | property | A `track`, or `missing value` when nothing is loaded. |

A `track` has `name`, `artist`, `album`, `duration` (milliseconds), `id` and
`spotify url` (both the Spotify URI).

Not supported yet: volume, shuffle, repeat, `player position`, `artwork url`,
and the `in context` parameter of `play track`.

### Examples

```applescript
tell application "Veya"
    playpause
    next track
    play track "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"
end tell
```

```applescript
tell application "Veya"
    if player state is playing then
        return name of current track & " - " & artist of current track
    end if
end tell
```

From the shell, or a Raycast or Alfred script command:

```sh
osascript -e 'tell application "Veya" to playpause'
osascript -e 'tell application "Veya" to get spotify url of current track'
```

The first script that talks to Veya triggers macOS's Automation prompt; allow it,
or grant it later in System Settings > Privacy & Security > Automation.

### Errors

| Number | Message |
|--------|---------|
| -10000 | Veya isn't signed in or couldn't start playback. |
| -10000 | That isn't a Spotify URI, such as spotify:track:… |

## Links

Veya opens `veya://<type>/<id>` links (PBI-606), where `<type>` is `track`,
`episode`, `album`, `artist`, `playlist` or `show` and `<id>` is the Spotify ID:

```sh
open veya://album/4aawyAB9vmqN3uQ7FjRGTy
```

Albums, artists, playlists and shows open their page; tracks and episodes play.
File > Open Link (⌘O) takes the same items as an `open.spotify.com` link or a
`spotify:` URI. Veya never registers the `spotify:` scheme, so links elsewhere
keep opening the official app.

# keyboard

the whole app is one big `Shortcuts` + `Actions` graph. the loop i use every day:

```
⌘K        open the palette
type      live soundcloud results, debounced 250 ms
↑ / ↓     move through results
↵         open the track / playlist / artist
↵         on a track page: play it, related tracks become the queue
space     pause / resume
→ / ←     seek 5 s
⇧ → / ←   next / previous track
⇧ ↑ / ↓   volume
esc       close the palette
```

![⌘K palette over the blurred app with live soundcloud results](../screenshots/omnibox.png)

## all shortcuts

| key | does |
|---|---|
| `space` | play / pause |
| `→` `←` | seek 5 s |
| `⇧` `→` `←` | next / previous track |
| `⇧` `↑` `↓` | volume |
| `M` | mute |
| `L` | like what's playing |
| `⇧` `L` | repeat |
| `R` | repost what's playing |
| `⇧` `S` | shuffle |
| `0` … `9` | jump to 0-90 % |
| `P` | go to the playing track |
| `S` | search |
| `Q` | queue |
| `H` | shortcut cheat sheet |
| `G` then `L` `S` `C` `P` `H` | likes / feed / library / profile / history |
| `⌘K` or `⌘F` | palette |
| `⌘L` | library / likes |
| `⌘,` | settings |
| `⌘` `⇧` `L` | logs |
| `⌘` `⇧` `C` | copy link to the current page or track |
| `↵` on `/track/:id` | play this page's track |

⌘ on macos, ctrl on windows and linux. single-key shortcuts go quiet while a text field or the palette has focus

## palette actions

in the palette you can also type action words: `settings`, `logs`, `likes`, `shuffle`, `sign out`, `clear cache`. they show up as rows, enter fires them

## right-click

every track row has a right-click menu: play, add to queue, like, repost, copy link, open on soundcloud, open artist, open track page

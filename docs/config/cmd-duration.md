# Command Duration (`$cmd_duration`)

The `cmd_duration` module displays the elapsed execution time of the previous command if it exceeded a configurable threshold.

## Format Variables

| Variable | Description |
|---|---|
| `$duration` | Formatted duration string (e.g. `2s`, `1m 32s`, `450ms`) |
| `$style` | Style string defined in `style` |

---

## Configuration Options

| Option | Type | Default | Description |
|---|---|---|---|
| `min_time` | `integer` | `2000` | Minimum execution duration in **milliseconds** required to display the module |
| `format` | `string` | `"took [$duration]($style) "` | Format template |
| `style` | `style` | `"bold yellow"` | Style for the duration string |
| `show_milliseconds` | `boolean` | `false` | Display milliseconds when execution is under 1 minute |
| `disabled` | `boolean` | `false` | Disables the cmd_duration module |

---

## Example

```toml
[cmd_duration]
min_time = 1000
show_milliseconds = true
format = "took [󰅐 $duration]($style) "
style = "bold #f1fa8c"
disabled = false
```

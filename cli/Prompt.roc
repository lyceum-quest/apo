# Interactive terminal input: the provider and model picker, and a key prompt that shows nothing.
import pf.Stderr
import pf.Stdin
import pf.Tty

import apo.Picker

Prompt :: [].{
	## The chosen item's value, or with `free_text` whatever was typed when nothing matches.
	pick! : Str, List(Picker.Item), Bool => Try(Str, [Failed(Str)])
	pick! = |title, items, free_text| {
		Tty.enable_raw_mode!().map_err(|_| Failed("cannot read keys from this terminal"))?
		result = pick_loop!(title, items, free_text)
		_ = Tty.disable_raw_mode!()
		result
	}

	pick_loop! : Str, List(Picker.Item), Bool => Try(Str, [Failed(Str)])
	pick_loop! = |title, items, free_text| {
		var $state = Picker.start
		while Bool.True {
			lines = Picker.view(title, $state, items, 12, free_text)
			draw!("${Str.join_with(lines, "\r\n")}\r\n")
			for key in Picker.keys(Stdin.bytes!() ?? [3]) {
				match key {
					Cancel => {
						erase!(lines.len())
						return Err(Failed("cancelled"))
					}
					Enter => match Picker.chosen($state, items, free_text) {
						Ok(value) => {
							erase!(lines.len())
							draw!("${title}: ${value}\r\n")
							return Ok(value)
						}
						Err(_) => {}
					}
					other => {
						$state = Picker.update($state, items, other)
					}
				}
			}
			erase!(lines.len())
		}
	}

	## A line typed without being shown, for an API key.
	secret! : Str => Try(Str, [Failed(Str)])
	secret! = |question| {
		draw!("${question}: ")
		Tty.enable_raw_mode!().map_err(|_| Failed("cannot read keys from this terminal"))?
		result = secret_loop!()
		_ = Tty.disable_raw_mode!()
		draw!("\r\n")
		result
	}

	secret_loop! : () => Try(Str, [Failed(Str)])
	secret_loop! = || {
		var $text = ""
		while Bool.True {
			for key in Picker.keys(Stdin.bytes!() ?? [3]) {
				match key {
					Enter => return Ok($text.trim())
					Cancel => return Err(Failed("cancelled"))
					Backspace => {
						$text = Picker.drop_last($text)
					}
					Text(t) => {
						$text = "${$text}${t}"
					}
					_ => {}
				}
			}
		}
	}

	draw! : Str => {}
	draw! = |text| {
		_ = Stderr.write!(text)
		{}
	}

	## Moves up over `lines` drawn lines and clears from there down.
	erase! : U64 => {}
	erase! = |lines| draw!("\u(1b)[${lines.to_str()}A\u(1b)[J")
}

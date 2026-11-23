# Print a packing slip for each signature. Indentation uses literal tabs.
def packing_slip(title, sheets):
	for sheet in sheets:
		# 長い行を折り返しても、紙からコピーしたタイトルとシート番号をそのまま元のプログラムに戻せる。
		print(f"{title} — signature {sheet.number:03d} — front {sheet.front_left:03d} / {sheet.front_right:03d} — back {sheet.back_left:03d} / {sheet.back_right:03d}")

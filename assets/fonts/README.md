# Receipt fonts

`ReceiptSans-Regular.ttf` and `ReceiptSans-Bold.ttf` are subsets of **Work
Sans** by Wei Huang, used under the SIL Open Font License 1.1 (`OFL.txt`).

They exist for one reason: the PDF standard fonts have no **₱**. Every amount
on a receipt printed with Helvetica came out as an empty box, which is not a
receipt a Philippine customer should be handed.

The subset keeps basic Latin, the Vietnamese vowels in "Cà Phê", the peso
sign, and the punctuation the receipt layout uses — 37 KB a face instead of
185 KB. Regenerate with `fonttools subset` if the receipt ever needs a
character outside that set; a missing glyph shows as a blank box, so it will
be obvious.

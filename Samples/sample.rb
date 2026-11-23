# A paper tray that knows how many sheets are left.
class PaperTray
  attr_reader :name, :sheets

  def initialize(name, sheets: 250)
    @name = name
    @sheets = sheets
  end

  def take(count)
    raise ArgumentError, "紙が足りません" if count > sheets

    @sheets -= count
    self
  end

  def empty? = sheets.zero?
end

tray = PaperTray.new("A4", sheets: 12)
tray.take(5).take(4)
puts "#{tray.name}: 残り #{tray.sheets} 枚#{' (空)' if tray.empty?}"

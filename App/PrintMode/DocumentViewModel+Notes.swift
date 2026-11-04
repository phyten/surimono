import SurimonoCore

extension DocumentViewModel {
    /// A binder keeps its documents as they are, so note pages are for a document of its own.
    var offersNotes: Bool { binder == nil }

    /// The name of the preset the note pages come from; nil when that preset is no longer there.
    var notePresetName: String? {
        guard let id = notes.presetID else { return nil }
        if let preset = NotePaperPreset.preset(id: id) { return String(localized: .init(preset.englishName)) }
        return preferences.notePresets.first { $0.id == id }?.name
    }

    var selectedOwnNotePreset: NoteUserPreset? {
        preferences.notePresets.first { $0.id == notes.presetID }
    }

    /// The note pages' style differs from the preset they came from.
    var isNoteStyleChanged: Bool {
        guard let id = notes.presetID else { return false }
        let style = NotePaperPreset.preset(id: id)?.style ?? selectedOwnNotePreset?.style
        return style.map { $0 != notes.style } ?? false
    }

    func chooseNotePreset(id: String, style: NotePaperStyle) {
        notes.presetID = id
        notes.style = style
    }

    func presentNoteSettings() {
        showsNoteSettings = true
        isPrintFinishPresented = true
    }

    /// Keeps the note pages' current style under a new name and goes on from there.
    func saveNotePreset(named name: String) {
        let preset = preferences.saveNotePreset(named: name, style: notes.style)
        notes.presetID = preset.id
    }

    /// Only the reader's own presets can be replaced.
    func overwriteNotePreset() {
        guard let preset = selectedOwnNotePreset else { return }
        preferences.overwriteNotePreset(preset.id, style: notes.style)
    }

    func removeNotePreset(_ id: String) {
        preferences.removeNotePreset(id)
    }
}

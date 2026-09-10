import SwiftUI

// Supported Whisper language tokens, including large-v3's Cantonese token.
// https://github.com/openai/whisper/blob/main/whisper/tokenizer.py
private struct NoteLanguage: Identifiable {
    let id: String
    var name: String { Locale.current.localizedString(forLanguageCode: id) ?? id }
    var nativeName: String { Locale(identifier: id).localizedString(forLanguageCode: id) ?? name }
    static let all: [NoteLanguage] = """
    en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no
    th ur hr bg lt la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw
    gl mr pa si km sn yo so af oc ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo tl
    mg as tt haw ln ha ba jw su yue
    """.split(whereSeparator: { $0.isWhitespace }).map { NoteLanguage(id: String($0)) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

public struct LanguagePicker: View {
    @Binding var selection: String
    public init(selection: Binding<String>) { _selection = selection }
    public var body: some View {
        NavigationLink {
            LanguageList(selection: $selection)
        } label: {
            LabeledContent("Language", value: selection.isEmpty ? "Detect automatically" : NoteLanguage(id: selection).name)
        }.accessibilityIdentifier("language-picker")
    }
}

private struct LanguageList: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        List {
            Section { option(code: "", name: "Detect automatically", detail: "Let Whisper identify the spoken language") }
            Section {
                ForEach(NoteLanguage.all.filter { search.isEmpty || $0.name.localizedStandardContains(search) || $0.nativeName.localizedStandardContains(search) || $0.id.localizedStandardContains(search) }) { language in
                    option(code: language.id, name: language.name, detail: "\(language.nativeName) · \(language.id)")
                }
            }
        }
        .inlineTitle("Language")
        .languageSearch($search)
    }
    private func option(code: String, name: String, detail: String) -> some View {
        Button {
            selection = code; dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selection == code { Image(systemName: "checkmark") }
            }
        }.accessibilityIdentifier("language-\(code.isEmpty ? "auto" : code)")
            .accessibilityValue(selection == code ? "Selected" : "")
    }
}


extension View {
    func languageSearch(_ search: Binding<String>) -> some View {
        #if os(iOS)
        searchable(text: search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search name or code")
        #else
        searchable(text: search, prompt: "Search name or code")
        #endif
    }
}

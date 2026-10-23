//
//  TemplateSheets.swift
//  PromptSchedule
//

import SwiftUI
import SwiftData

/// Asks for the values of a template's own `{{placeholders}}`.
struct TemplateFillSheet: View {
    let template: PromptTemplate
    let onInsert: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    private var variables: [String] { TemplateEngine.userVariables(in: template.body) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(template.name).font(.title2.bold())
            Form {
                ForEach(variables, id: \.self) { name in
                    TextField(name, text: Binding(
                        get: { values[name, default: ""] },
                        set: { values[name] = $0 }
                    ))
                }
            }
            Text(TemplateEngine.fill(template.body, with: values))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Text("{{folder}}, {{branch}}, {{cwd}}, {{date}} and {{time}} are filled in for each session when sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Insert") {
                    onInsert(TemplateEngine.fill(template.body, with: values))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Saves the current composer text as a new template.
struct SaveTemplateSheet: View {
    let text: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as Template").font(.title2.bold())
            TextField("Template name", text: $name)
                .textFieldStyle(.roundedBorder)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(6)
            Text("Tip: use {{name}} for values to fill in later, or {{folder}} / {{branch}} for per-session values.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    modelContext.insert(PromptTemplate(name: name.trimmingCharacters(in: .whitespaces), body: text))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// Lists templates for renaming, editing and deleting.
struct ManageTemplatesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PromptTemplate.name) private var templates: [PromptTemplate]
    @State private var selection: PromptTemplate?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Templates").font(.title2.bold())
            HSplitView {
                List(templates, id: \.self, selection: $selection) { template in
                    Text(template.name)
                        .contextMenu {
                            Button("Delete", role: .destructive) { delete(template) }
                        }
                }
                .frame(minWidth: 180)

                Group {
                    if let selection {
                        @Bindable var template = selection
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Name", text: $template.name)
                                .textFieldStyle(.roundedBorder)
                            TextEditor(text: $template.body)
                                .font(.body)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                            HStack {
                                Text("Variables: \(TemplateEngine.placeholders(in: template.body).joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Delete", role: .destructive) { delete(selection) }
                            }
                        }
                        .padding(.leading, 8)
                    } else {
                        ContentUnavailableView("Select a template", systemImage: "doc.text")
                    }
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button {
                    let template = PromptTemplate(name: "New Template", body: "")
                    modelContext.insert(template)
                    selection = template
                } label: {
                    Label("New Template", systemImage: "plus")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680, height: 440)
    }

    private func delete(_ template: PromptTemplate) {
        if selection == template { selection = nil }
        modelContext.delete(template)
    }
}

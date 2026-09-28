import XMPPXML

extension Namespaces {
    public static let dataForms = "jabber:x:data"
}

/// XEP-0004 data form: fields with their values, options and constraints.
/// Rendering lives with the features that present forms to the user (room
/// configuration).
public struct DataForm: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case form, submit, cancel, result
    }

    public struct Field: Sendable, Hashable {
        /// §3.3: a choice in a `list-single` or `list-multi` field.
        public struct Option: Sendable, Hashable {
            public var label: String?
            public var value: String

            public init(label: String? = nil, value: String) {
                self.label = label
                self.value = value
            }
        }

        public var variable: String?
        /// §3.3 field type; `nil` means `text-single`.
        public var type: String?
        public var label: String?
        public var description: String?
        public var isRequired: Bool
        public var values: [String]
        public var options: [Option]

        public init(variable: String?, type: String? = nil, label: String? = nil, description: String? = nil,
                    isRequired: Bool = false, values: [String] = [], options: [Option] = []) {
            self.variable = variable
            self.type = type
            self.label = label
            self.description = description
            self.isRequired = isRequired
            self.values = values
            self.options = options
        }

        /// §3.3: `boolean` values are "1"/"true" or "0"/"false".
        public var boolValue: Bool {
            get { values.first.map { $0 == "1" || $0 == "true" } ?? false }
            set { values = [newValue ? "1" : "0"] }
        }
    }

    public var type: Kind
    public var title: String?
    public var instructions: [String]
    public var fields: [Field]

    public init(type: Kind, title: String? = nil, instructions: [String] = [], fields: [Field] = []) {
        self.type = type
        self.title = title
        self.instructions = instructions
        self.fields = fields
    }

    public init?(element: Element) {
        guard element.matches(name: "x", namespaceURI: Namespaces.dataForms),
              let type = element["type"].flatMap(Kind.init(rawValue:)) else { return nil }
        self.type = type
        title = element.firstChild(name: "title", namespaceURI: Namespaces.dataForms)?.text
        instructions = element.childElements(name: "instructions", namespaceURI: Namespaces.dataForms).map(\.text)
        fields = element.childElements(name: "field", namespaceURI: Namespaces.dataForms).map { field in
            Field(variable: field["var"], type: field["type"], label: field["label"],
                  description: field.firstChild(name: "desc", namespaceURI: Namespaces.dataForms)?.text,
                  isRequired: field.firstChild(name: "required", namespaceURI: Namespaces.dataForms) != nil,
                  values: field.childElements(name: "value", namespaceURI: Namespaces.dataForms).map(\.text),
                  options: field.childElements(name: "option", namespaceURI: Namespaces.dataForms).compactMap { option in
                      option.firstChild(name: "value", namespaceURI: Namespaces.dataForms)
                          .map { Field.Option(label: option["label"], value: $0.text) }
                  })
        }
    }

    /// The hidden `FORM_TYPE` field (XEP-0068) that names the form's schema.
    public var formType: String? {
        fields.first { $0.variable == "FORM_TYPE" }?.values.first
    }

    public subscript(variable: String) -> [String]? {
        fields.first { $0.variable == variable }?.values
    }

    /// Sets the values of an existing field; returns `false` when the form
    /// has no such field (servers differ in what they offer).
    @discardableResult
    public mutating func set(_ variable: String, _ values: [String]) -> Bool {
        guard let index = fields.firstIndex(where: { $0.variable == variable }) else { return false }
        fields[index].values = values
        return true
    }

    /// The form to send back: §3.2 says a submission carries values only,
    /// so labels, descriptions and options are left out; `fixed` fields,
    /// which carry no data, are dropped.
    public func submission() -> DataForm {
        DataForm(type: .submit, fields: fields.compactMap { field in
            guard field.variable != nil, field.type != "fixed" else { return nil }
            return Field(variable: field.variable, type: field.type, values: field.values)
        })
    }

    public var element: Element {
        var x = Element(name: "x", namespaceURI: Namespaces.dataForms, attributes: ["type": type.rawValue])
        if let title { x.addChild(Element(name: "title", namespaceURI: Namespaces.dataForms, text: title)) }
        for line in instructions {
            x.addChild(Element(name: "instructions", namespaceURI: Namespaces.dataForms, text: line))
        }
        for field in fields {
            var f = Element(name: "field", namespaceURI: Namespaces.dataForms)
            f["var"] = field.variable
            f["type"] = field.type
            f["label"] = field.label
            if let description = field.description {
                f.addChild(Element(name: "desc", namespaceURI: Namespaces.dataForms, text: description))
            }
            if field.isRequired { f.addChild(Element(name: "required", namespaceURI: Namespaces.dataForms)) }
            for value in field.values {
                f.addChild(Element(name: "value", namespaceURI: Namespaces.dataForms, text: value))
            }
            for option in field.options {
                var o = Element(name: "option", namespaceURI: Namespaces.dataForms)
                o["label"] = option.label
                o.addChild(Element(name: "value", namespaceURI: Namespaces.dataForms, text: option.value))
                f.addChild(o)
            }
            x.addChild(f)
        }
        return x
    }
}

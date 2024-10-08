public struct GenerateMockMacro: PeerMacro {
    enum Error: String, Swift.Error, DiagnosticMessage {
        var diagnosticID: MessageID { .init(domain: "GenerateMockMacro", id: rawValue) }
        var severity: DiagnosticSeverity { .error }
        var message: String {
            switch self {
            case .notAProtocol: return "@GenerateMock can only be applied to protocols"
            }
        }

        case notAProtocol
    }

    public static func expansion<Context: MacroExpansionContext, Declaration: DeclSyntaxProtocol>(
        of node: AttributeSyntax,
        providingPeersOf declaration: Declaration,
        in context: Context
    ) throws -> [DeclSyntax] {
        guard let protoDecl = declaration.as(ProtocolDeclSyntax.self) else { throw Error.notAProtocol }

        // Instance properties
        let mockMemberProperties = protoDecl.properties
            .map { DeclSyntax("\(raw: protoDecl.declAccessLevel == .public ? "public" : "internal") var \(raw: $0.identifier.text): MockMember<\(raw: $0.type!.type.trimmed), \(raw: $0.returnType)> = .init()") }
            .compactMap { MemberBlockItemSyntax(decl: $0) }

        let properties = protoDecl.properties
            .map { $0.makeMockProperty(accessLevel: protoDecl.declAccessLevel) }
            .compactMap { MemberBlockItemSyntax(decl: $0) }

        // Instance functions
        let mockMemberFunctions = protoDecl.functions
            .map { DeclSyntax("\(raw: protoDecl.declAccessLevel == .public ? "public" : "internal") var \(raw: $0.name.text): MockMember<(\(raw: $0.parameters.typesWithoutAttribues.map(\.description).joined(separator: ", "))), \(raw: $0.returnTypeOrVoid)> = .init()") }
            .compactMap { MemberBlockItemSyntax(decl: $0) }

        let functions = protoDecl.functions
            .map { $0.makeMockFunction(accessLevel: protoDecl.declAccessLevel) }
            .compactMap { MemberBlockItemSyntax(decl: $0) }

        // Consolidation
        let mockMemberMembers = MemberBlockItemListSyntax(mockMemberProperties + mockMemberFunctions)

        let mockMembers = ClassDeclSyntax(
            modifiers: DeclModifierListSyntax {
                DeclModifierSyntax(name: protoDecl.declAccessLevel == .public ? "public" : "internal")
            },
            name: "Members",
            memberBlock: MemberBlockSyntax(members: mockMemberMembers)
        )

        // Associatedtypes
        var genericParams: GenericParameterClauseSyntax?
        let associatedTypes = protoDecl.associatedTypes
        if !associatedTypes.isEmpty {
            let params = protoDecl.associatedTypes.enumerated().map { x, type in
                return type.genericParameter.with(\.trailingComma, x == associatedTypes.count - 1 ? nil : .commaToken())
            }
            genericParams = GenericParameterClauseSyntax(parameters: .init(params))
        }

        let cls = try ClassDeclSyntax(
            modifiers: DeclModifierListSyntax {
                DeclModifierSyntax(name: protoDecl.declAccessLevel == .public ? "open" : "internal")
            },
            name: "\(raw: protoDecl.name.text)Mock",
            genericParameterClause: genericParams,
            inheritanceClause: InheritanceClauseSyntax {
                InheritedTypeSyntax(type: TypeSyntax("\(raw: protoDecl.name.text)"))
                if let inheritance = protoDecl.inheritanceClause?.inheritedTypes {
                    inheritance
                }
            },
            genericWhereClause: nil,
            memberBlockBuilder: {
                DeclSyntax("\(raw: protoDecl.declAccessLevel == .public ? "public" : "internal") let mocks = Members()")

                mockMembers

                let initializers = protoDecl.initializers
                if initializers.isEmpty, protoDecl.declAccessLevel == .public {
                    DeclSyntax("public init() {}")
                }
                for initializer in initializers {
                    try InitializerDeclSyntax(validating: initializer)
                        .with(\.body, CodeBlockSyntax {
                            DeclSyntax("// ")
                        })
                }

                MemberBlockItemListSyntax(properties)
                MemberBlockItemListSyntax(functions)
            }
        )

        return [
            "#if DEBUG",
            DeclSyntax(cls),
            "#endif"
        ]
    }
}

private extension VariableDeclSyntax {
    /// Take a `VariableDeclSyntax` from the source protocol and add `AccessorDeclSyntax`s for the getter and, if needed, setter
    func makeMockProperty(accessLevel: AccessLevelModifier) -> VariableDeclSyntax {
        var newProperty = trimmed
        var binding = newProperty.bindings.first!
        let accessor = binding.accessorBlock!

        switch accessor.accessors {
        case .getter/*(let getter)*/:
            fatalError("Protocols shouldn't hit here")

        case .accessors(var accessors):
            let getter = accessors.first!

            accessors = []
            accessors = accessors.appending("\(raw: getter.description) { \(raw: getter.effectSpecifiers?.throwsSpecifier != nil ? "try " : "")mocks.\(raw: newProperty.identifier.text).getter() }")
            if getter.effectSpecifiers == nil {
                accessors = accessors.appending("set { mocks.\(raw: identifier.text).setter(newValue) }")
            }
            accessors = accessors.trimmed

            binding.accessorBlock = .init(accessors: .accessors(accessors))
            newProperty.accessLevel = accessLevel == .public ? .open : .internal

            newProperty.bindings = .init { binding }
            return newProperty.trimmed

//            var newAccessor = newProperty.bindings[newProperty.bindings.startIndex]
//            newAccessor.accessorBlock = .init(accessors)
//            var newBinding = newProperty.bindings[newProperty.bindings.startIndex]
//            newBinding.accessorBlock = .init(newAccessor)
//            newProperty.bindings = newProperty.bindings.replacing(childAt: 0, with: newBinding)
//            return newProperty.trimmed
        }
    }
}

private extension FunctionDeclSyntax {
    func makeMockFunction(accessLevel: AccessLevelModifier) -> FunctionDeclSyntax {
        var newFunction = trimmed

        var newSignature = signature
        var params: [String] = []
        for (x, param) in signature.parameterClause.parameters.enumerated() {
            var newParam = param
            newParam.secondName = "arg\(raw: x)"
            newSignature.parameterClause.parameters = newSignature.parameterClause.parameters.replacing(childAt: x, with: newParam)
            params.append("arg\(x)")
        }

        let publicAccess: AccessLevelModifier = isStatic ? .public : .open
        newFunction.accessLevel = accessLevel == .public ? publicAccess : .internal
        newFunction.signature = newSignature
        newFunction.body = CodeBlockSyntax(statementsBuilder: {
            CodeBlockItemSyntax(item: .stmt("return \(raw: isThrowing ? "try " : "")mocks.\(raw: name.text).execute((\(raw: params.joined(separator: ", "))))"))
        })
        return newFunction
    }
}

private extension VariableDeclSyntax {
    var returnType: DeclSyntax {
        if isThrowing { return "\(raw: "Result<\(type!.type.trimmed), Error>")" }
        else { return "\(raw: type!.type.trimmed)" }
    }
}
private extension FunctionDeclSyntax {
    var returnTypeOrVoid: DeclSyntax {
        if isThrowing { return "Result<\(raw: returnOrVoid.type), Error>" }
        else { return "\(raw: returnOrVoid.type)" }
    }
}
private extension AssociatedTypeDeclSyntax {
    var genericParameter: GenericParameterSyntax {
        let type = self.inheritanceClause?.inheritedTypes.first

        return GenericParameterSyntax(
            attributes: attributes,
            name: name,
            colon: type.map { _ in .colonToken() },
            inheritedType: type.map { TypeSyntax("\(raw: $0)") }
        )
    }
}

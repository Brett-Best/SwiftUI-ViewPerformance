import Foundation
import MachO

private func getTypeName(descriptor: UnsafePointer<TargetModuleContextDescriptor>) -> String? {
  let flags = descriptor.pointee.flags
  var parentName: String? = nil
  if descriptor.pointee.parent != 0 {
    let parent = UnsafeRawPointer(descriptor).advanced(by: MemoryLayout<TargetModuleContextDescriptor>.offset(of: \.parent)!).advanced(by: Int(descriptor.pointee.parent))
    if abs(descriptor.pointee.parent) % 2 == 1 {
      return nil
    }
    parentName = getTypeName(descriptor: parent.assumingMemoryBound(to: TargetModuleContextDescriptor.self))
  }
  switch flags.kind {
  case .Module, .Enum, .Struct, .Class:
    let name = UnsafeRawPointer(descriptor)
      .advanced(by: MemoryLayout<TargetModuleContextDescriptor>.offset(of: \.name)!)
      .advanced(by: Int(descriptor.pointee.name))
      .assumingMemoryBound(to: CChar.self)
    let typeName = String(cString: name)
    if let parentName = parentName {
      return "\(parentName).\(typeName)"
    }
    return typeName
  default:
    return parentName
  }
}

typealias LookupResult = (name: String, proto: String, body: UInt64)

private func parseConformance(conformance: UnsafePointer<ProtocolConformanceDescriptor>, names: [String]) -> LookupResult? {
  let flags = conformance.pointee.conformanceFlags

  guard case .DirectTypeDescriptor = flags.kind else {
    return nil
  }

  guard conformance.pointee.protocolDescriptor % 2 == 1 else {
    return nil
  }
  let descriptorOffset = Int(conformance.pointee.protocolDescriptor & ~1)
  let jumpPtr = UnsafeRawPointer(conformance).advanced(by: MemoryLayout<ProtocolConformanceDescriptor>.offset(of: \.protocolDescriptor)!).advanced(by: descriptorOffset)
  let address = jumpPtr.load(as: UInt64.self)

  // Address will be 0 if the protocol is not available (such as only defined on a newer OS)
  guard address != 0 else {
    return nil
  }
  let protoPtr = UnsafeRawPointer(bitPattern: UInt(address))!
  let proto = protoPtr.load(as: ProtocolDescriptor.self)
  let namePtr = protoPtr.advanced(by: MemoryLayout<ProtocolDescriptor>.offset(of: \.name)!).advanced(by: Int(proto.name))
  let protocolName = String(cString: namePtr.assumingMemoryBound(to: CChar.self))
  guard names.contains(protocolName) else {
    return nil
  }

  let typeDescriptorPointer = UnsafeRawPointer(conformance).advanced(by: MemoryLayout<ProtocolConformanceDescriptor>.offset(of: \.nominalTypeDescriptor)!).advanced(by: Int(conformance.pointee.nominalTypeDescriptor))

  let descriptor = typeDescriptorPointer.assumingMemoryBound(to: TargetModuleContextDescriptor.self)
  guard !descriptor.pointee.flags.isGeneric else {
    return nil
  }

  if let name = getTypeName(descriptor: descriptor),
     [ContextDescriptorKind.Class, ContextDescriptorKind.Struct, ContextDescriptorKind.Enum].contains(descriptor.pointee.flags.kind) {
    return (name, protocolName, 0)
  }
  return nil
}

/// Parse Layout conformances without skipping generic types
private func parseLayoutConformance(conformance: UnsafePointer<ProtocolConformanceDescriptor>) -> LookupResult? {
  let flags = conformance.pointee.conformanceFlags

  guard case .DirectTypeDescriptor = flags.kind else {
    return nil
  }

  guard conformance.pointee.protocolDescriptor % 2 == 1 else {
    return nil
  }
  let descriptorOffset = Int(conformance.pointee.protocolDescriptor & ~1)
  let jumpPtr = UnsafeRawPointer(conformance).advanced(by: MemoryLayout<ProtocolConformanceDescriptor>.offset(of: \.protocolDescriptor)!).advanced(by: descriptorOffset)
  let address = jumpPtr.load(as: UInt64.self)

  // Address will be 0 if the protocol is not available (such as only defined on a newer OS)
  guard address != 0 else {
    return nil
  }
  let protoPtr = UnsafeRawPointer(bitPattern: UInt(address))!
  let proto = protoPtr.load(as: ProtocolDescriptor.self)
  let namePtr = protoPtr.advanced(by: MemoryLayout<ProtocolDescriptor>.offset(of: \.name)!).advanced(by: Int(proto.name))
  let protocolName = String(cString: namePtr.assumingMemoryBound(to: CChar.self))
  guard protocolName == "Layout" else {
    return nil
  }

  let typeDescriptorPointer = UnsafeRawPointer(conformance).advanced(by: MemoryLayout<ProtocolConformanceDescriptor>.offset(of: \.nominalTypeDescriptor)!).advanced(by: Int(conformance.pointee.nominalTypeDescriptor))

  let descriptor = typeDescriptorPointer.assumingMemoryBound(to: TargetModuleContextDescriptor.self)
  
  // Do NOT skip generic types for Layout (unlike View parsing)
  // Many Layout conformances are generic, e.g., LoggedLayout<Base>

  if let name = getTypeName(descriptor: descriptor),
     [ContextDescriptorKind.Class, ContextDescriptorKind.Struct, ContextDescriptorKind.Enum].contains(descriptor.pointee.flags.kind) {
    return (name, protocolName, 0)
  }
  return nil
}

#if arch(i386) || arch(arm) || arch(arm64_32)
typealias mach_header_type = mach_header
#else
typealias mach_header_type = mach_header_64
#endif

func getViews() -> [LookupResult] {
  let images = _dyld_image_count()
  var types = [LookupResult]()
  for i in 0..<images {
    let header = _dyld_get_image_header(i)!
    let headerType = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_type.self)

    // Anything in the dylib cache is a system library that we should not include
    guard headerType.pointee.flags & MH_DYLIB_IN_CACHE == 0 else {
      continue
    }

    let imageName = String(cString: _dyld_get_image_name(i))
    guard !imageName.contains(".simruntime") && !imageName.contains(".platform") && !imageName.starts(with: "/usr/lib/") && !imageName.starts(with: "/System/Library/") else {
      continue
    }

    let target = lookupSwiftUIViewBodyRequirementDescriptor()!
    var size: UInt = 0
    let sectStart = UnsafeRawPointer(
      getsectiondata(
        headerType,
        "__TEXT",
        "__swift5_proto",
        &size))?.assumingMemoryBound(to: Int32.self)
    if var sectData = sectStart {
      for _ in 0..<Int(size)/MemoryLayout<Int32>.size {
        let conformanceRaw = UnsafeRawPointer(sectData)
          .advanced(by: Int(sectData.pointee))
        let conformance = conformanceRaw
          .assumingMemoryBound(to: ProtocolConformanceDescriptor.self)
        if let result = parseConformance(conformance: conformance, names: ["View"]) {
          print(result.name)
            if let offset = findBodyDescriptorFieldOffsetByResolvingRelatives(record: conformance, bodyDescriptor: target, maxBytes: 256) {
              let funcOffsetPtr = conformanceRaw.advanced(by: offset * 4 + 4)
              let offsetToFunc = funcOffsetPtr.load(as: Int32.self)
              if let bodyThunk = resolveRelativePointer(fieldAddr: funcOffsetPtr, raw: offsetToFunc) {
                types.append((result.0, result.1, UInt64(Int(bitPattern: bodyThunk))))
              }
            }
        }
        sectData = sectData.successor()
      }
    }
  }
  return types
}

/// Scans loaded images for types conforming to SwiftUI's `Layout` protocol
/// and returns their `sizeThatFits(proposal:subviews:cache:)` thunks.
func getLayouts() -> [LookupResult] {
  guard let target = lookupSwiftUILayoutSizeThatFitsRequirementDescriptor() else {
    print("Warning: Could not resolve Layout.sizeThatFits requirement descriptor - Layout tracking will be disabled")
    return []
  }
  
  let images = _dyld_image_count()
  var types = [LookupResult]()
  for i in 0..<images {
    let header = _dyld_get_image_header(i)!
    let headerType = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_type.self)

    // Anything in the dylib cache is a system library that we should not include
    guard headerType.pointee.flags & MH_DYLIB_IN_CACHE == 0 else {
      continue
    }

    let imageName = String(cString: _dyld_get_image_name(i))
    guard !imageName.contains(".simruntime") && !imageName.contains(".platform") && !imageName.starts(with: "/usr/lib/") && !imageName.starts(with: "/System/Library/") else {
      continue
    }
    
    var size: UInt = 0
    let sectStart = UnsafeRawPointer(
      getsectiondata(
        headerType,
        "__TEXT",
        "__swift5_proto",
        &size))?.assumingMemoryBound(to: Int32.self)
    if var sectData = sectStart {
      for _ in 0..<Int(size)/MemoryLayout<Int32>.size {
        let conformanceRaw = UnsafeRawPointer(sectData)
          .advanced(by: Int(sectData.pointee))
        let conformance = conformanceRaw
          .assumingMemoryBound(to: ProtocolConformanceDescriptor.self)
        
        // Parse conformance but DO NOT skip generic types (unlike getViews)
        if let result = parseLayoutConformance(conformance: conformance) {
          print("Found Layout: \(result.name)")
          if let offset = findBodyDescriptorFieldOffsetByResolvingRelatives(record: conformance, bodyDescriptor: target, maxBytes: 256) {
            let funcOffsetPtr = conformanceRaw.advanced(by: offset * 4 + 4)
            let offsetToFunc = funcOffsetPtr.load(as: Int32.self)
            if let sizeThatFitsThunk = resolveRelativePointer(fieldAddr: funcOffsetPtr, raw: offsetToFunc) {
              types.append((result.0, result.1, UInt64(Int(bitPattern: sizeThatFitsThunk))))
            }
          }
        }
        sectData = sectData.successor()
      }
    }
  }
  return types
}

/// Resolves a Swift "relative reference" stored as an Int32 at `fieldAddr`.
/// - If `indirectable` is false: absolute = fieldAddr + raw
/// - If `indirectable` is true: raw may have low-bit tag 1 meaning "indirect":
///   absolute = *(fieldAddr + (raw & ~1)) if (raw & 1) != 0 else (fieldAddr + raw)
private func resolveRelativePointer(fieldAddr: UnsafeRawPointer, raw: Int32) -> UnsafeRawPointer? {
    let base = UInt(bitPattern: fieldAddr)

    // Indirectable encoding: low-bit tag indicates indirection.
    let isIndirect = (raw & 1) != 0
    let rawNoTag = raw & ~1

    let candidateAddr = Int(base) + Int(rawNoTag)
    guard let candidatePtr = UnsafeRawPointer(bitPattern: candidateAddr) else { return nil }

    if isIndirect {
        // candidatePtr points to a pointer-sized slot (e.g., GOT entry). Load the real pointer.
        let pointee = candidatePtr.loadUnaligned(as: UInt.self)
        return UnsafeRawPointer(bitPattern: pointee)
    } else {
        return candidatePtr
    }
}

/// Scans a conformance record region for an Int32 relative reference that resolves to `bodyDescriptor`.
/// Returns the byte offset of the Int32 field within `record`, or nil if not found.
///
/// - Parameters:
///   - record: base address of the conformance record.
///   - bodyDescriptor: absolute pointer to `$s7SwiftUI4ViewP4body4BodyQzvgTq` (a method descriptor).
///   - maxBytes: number of bytes to scan (must be safely readable).
func findBodyDescriptorFieldOffsetByResolvingRelatives(
    record: UnsafeRawPointer,
    bodyDescriptor: UnsafeRawPointer,
    maxBytes: Int
) -> Int? {
    precondition(maxBytes >= 4)

    let target = UInt(bitPattern: bodyDescriptor)

    // Try every byte offset as if it were the start of an Int32 relative ref.
    for offset in 0...(maxBytes/4) {
        let fieldAddr = record.advanced(by: offset*4)
        let raw = fieldAddr.loadUnaligned(as: Int32.self)

        if let p2 = resolveRelativePointer(fieldAddr: fieldAddr, raw: raw),
           UInt(bitPattern: p2) == target {
            return offset
        }
    }

    return nil
}

/// Returns the address of SwiftUI's `View.body` requirement descriptor:
/// `$s7SwiftUI4ViewP4body4BodyQzvgTq`
///
/// - Note: This is a *descriptor* address (not a function pointer).
func lookupSwiftUIViewBodyRequirementDescriptor() -> UnsafeMutableRawPointer? {
    let symbol = "$s7SwiftUI4ViewP4body4BodyQzvgTq"
    let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) // -2 == RTLD_DEFAULT
    if sym == nil, let err = dlerror() {
        let msg = String(cString: err)
        print("dlsym failed for \(symbol): \(msg)")
    }

    return sym
}

/// Returns the address of SwiftUI's `Layout.sizeThatFits(proposal:subviews:cache:)` requirement descriptor
/// by finding and introspecting the Layout protocol descriptor.
///
/// - Note: This is a *descriptor* address (not a function pointer).
func lookupSwiftUILayoutSizeThatFitsRequirementDescriptor() -> UnsafeMutableRawPointer? {
    // Try the primary known symbol first (fast path for matching versions)
    let primarySymbol = "$s7SwiftUI6LayoutP12sizeThatFits8proposal8subviews5cache7CoreFou0G4SizeVAA012ProposedViewJ0V_AA0i10SubviewsJ0Vz1_QPtFTq"
    var sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), primarySymbol) // -2 == RTLD_DEFAULT
    
    if sym != nil {
        print("Found Layout.sizeThatFits descriptor using primary symbol")
        return sym
    }
    
    // Primary symbol failed - try extracting from a known Layout conformance in SwiftUI
    print("Primary symbol lookup failed, attempting to extract from SwiftUI Layout conformances")
    
    if let descriptor = extractLayoutSizeThatFitsDescriptorFromSwiftUI() {
        print("Successfully extracted Layout.sizeThatFits descriptor from SwiftUI protocol conformance")
        return descriptor
    }
    
    // Last resort: try alternative symbol variations
    print("Extraction failed, trying alternative symbol variations")
    let alternativeSymbols = [
        "$s7SwiftUI6LayoutP12sizeThatFits8proposal8subviews5cache0G4SizeVAA012ProposedViewJ0V_AA0i10SubviewsJ0Vz1_QPtFTq",
        "$s7SwiftUI6LayoutP12sizeThatFits8proposal8subviews5cache7CoreFou0G4SizeVAA0bC0G0V_AA0i10SubviewsJ0Vz1_QPtFTq",
        "$s7SwiftUI6LayoutP12sizeThatFits8proposal8subviews7CoreFou0F4SizeVAA012ProposedViewI0V_AA0h10SubviewsI0VtFTq",
    ]
    
    for alternativeSymbol in alternativeSymbols {
        sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), alternativeSymbol)
        if sym != nil {
            print("Found Layout.sizeThatFits descriptor using alternative symbol")
            return sym
        }
    }
    
    print("Warning: Could not find Layout.sizeThatFits requirement descriptor through any method")
    return nil
}

/// Extracts the sizeThatFits requirement descriptor by finding a Layout conformance in SwiftUI
/// and reading its witness table structure.
private func extractLayoutSizeThatFitsDescriptorFromSwiftUI() -> UnsafeMutableRawPointer? {
    let images = _dyld_image_count()
    
    for i in 0..<images {
        let header = _dyld_get_image_header(i)!
        let headerType = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_type.self)
        
        let imageName = String(cString: _dyld_get_image_name(i))
        
        // Only look in SwiftUI framework itself - it should have Layout conformances
        guard imageName.contains("SwiftUI.framework") || imageName.contains("libswiftUI") else {
            continue
        }
        
        print("Searching for Layout protocol conformances in SwiftUI: \(imageName)")
        
        var size: UInt = 0
        let sectStart = UnsafeRawPointer(
            getsectiondata(
                headerType,
                "__TEXT",
                "__swift5_proto",
                &size))?.assumingMemoryBound(to: Int32.self)
        
        guard var sectData = sectStart else { continue }
        
        for _ in 0..<Int(size)/MemoryLayout<Int32>.size {
            let conformanceRaw = UnsafeRawPointer(sectData)
                .advanced(by: Int(sectData.pointee))
            let conformance = conformanceRaw
                .assumingMemoryBound(to: ProtocolConformanceDescriptor.self)
            
            // Check if this is a Layout protocol conformance
            if let layoutResult = parseLayoutConformanceForDescriptor(conformance: conformance) {
                print("Found Layout conformance in SwiftUI: \(layoutResult.name)")
                
                // Try to extract the sizeThatFits requirement descriptor from this conformance
                // The witness table should have references to requirement descriptors
                if let descriptor = extractRequirementDescriptorFromConformance(
                    conformance: conformance,
                    protocolName: "Layout",
                    methodName: "sizeThatFits"
                ) {
                    return descriptor
                }
            }
            
            sectData = sectData.successor()
        }
    }
    
    return nil
}

/// Parse a conformance to check if it's a Layout conformance (used for descriptor extraction)
private func parseLayoutConformanceForDescriptor(conformance: UnsafePointer<ProtocolConformanceDescriptor>) -> LookupResult? {
    let flags = conformance.pointee.conformanceFlags
    
    guard case .DirectTypeDescriptor = flags.kind else {
        return nil
    }
    
    guard conformance.pointee.protocolDescriptor % 2 == 1 else {
        return nil
    }
    
    let descriptorOffset = Int(conformance.pointee.protocolDescriptor & ~1)
    let jumpPtr = UnsafeRawPointer(conformance).advanced(by: MemoryLayout<ProtocolConformanceDescriptor>.offset(of: \.protocolDescriptor)!).advanced(by: descriptorOffset)
    let address = jumpPtr.load(as: UInt64.self)
    
    guard address != 0 else {
        return nil
    }
    
    let protoPtr = UnsafeRawPointer(bitPattern: UInt(address))!
    let proto = protoPtr.load(as: ProtocolDescriptor.self)
    let namePtr = protoPtr.advanced(by: MemoryLayout<ProtocolDescriptor>.offset(of: \.name)!).advanced(by: Int(proto.name))
    let protocolName = String(cString: namePtr.assumingMemoryBound(to: CChar.self))
    
    guard protocolName == "Layout" else {
        return nil
    }
    
    let typeDescriptorPointer = UnsafeRawPointer(conformance).advanced(by: MemoryLayout<ProtocolConformanceDescriptor>.offset(of: \.nominalTypeDescriptor)!).advanced(by: Int(conformance.pointee.nominalTypeDescriptor))
    let descriptor = typeDescriptorPointer.assumingMemoryBound(to: TargetModuleContextDescriptor.self)
    
    if let name = getTypeName(descriptor: descriptor),
       [ContextDescriptorKind.Class, ContextDescriptorKind.Struct, ContextDescriptorKind.Enum].contains(descriptor.pointee.flags.kind) {
        return (name, protocolName, 0)
    }
    return nil
}

/// Attempts to extract a specific requirement descriptor from a protocol conformance witness table
private func extractRequirementDescriptorFromConformance(
    conformance: UnsafePointer<ProtocolConformanceDescriptor>,
    protocolName: String,
    methodName: String
) -> UnsafeMutableRawPointer? {
    // The witness table offset is stored in the conformance
    // We need to scan through it to find requirement descriptors
    // This is a heuristic approach: scan the conformance record region for pointers
    // that look like they could be requirement descriptors
    
    let conformanceRaw = UnsafeRawPointer(conformance)
    let scanBytes = 512 // Scan a reasonable region
    
    // Look for patterns that match requirement descriptor references
    // Requirement descriptors typically have relative offsets
    for offset in stride(from: 0, to: scanBytes, by: 4) {
        let fieldAddr = conformanceRaw.advanced(by: offset)
        let raw = fieldAddr.loadUnaligned(as: Int32.self)
        
        // Skip if it doesn't look like a reasonable relative offset
        guard abs(raw) < 100000000 else { continue }
        
        if let ptr = resolveRelativePointer(fieldAddr: fieldAddr, raw: raw) {
            // Check if this pointer looks like it could be a requirement descriptor
            // by trying to read it as a string and looking for "sizeThatFits"
            let testPtr = ptr.assumingMemoryBound(to: UInt8.self)
            
            // Try to read a small region and look for ASCII patterns
            var bytes: [UInt8] = []
            for i in 0..<100 {
                let byte = testPtr.advanced(by: i).pointee
                if byte == 0 { break }
                if byte >= 32 && byte <= 126 {
                    bytes.append(byte)
                } else if bytes.count > 0 {
                    break
                }
            }
            
            if bytes.count > 0, let str = String(bytes: bytes, encoding: .utf8) {
                if str.contains("sizeThatFits") {
                    print("Found potential sizeThatFits requirement descriptor at offset \(offset)")
                    return UnsafeMutableRawPointer(mutating: ptr)
                }
            }
        }
    }
    
    return nil
}

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

    guard let target = lookupSwiftUILayoutSizeThatFitsRequirementDescriptor() else {
      print("Warning: Could not resolve Layout.sizeThatFits requirement descriptor")
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

/// Returns the address of SwiftUI's `Layout.sizeThatFits(proposal:subviews:cache:)` requirement descriptor:
/// `$s7SwiftUI6LayoutP12sizeThatFits8proposal8subviews5cache7CoreFou0G4SizeVAA012ProposedViewJ0V_AA0i10SubviewsJ0Vz1_QPtFTq`
///
/// - Note: This is a *descriptor* address (not a function pointer).
func lookupSwiftUILayoutSizeThatFitsRequirementDescriptor() -> UnsafeMutableRawPointer? {
    let symbol = "$s7SwiftUI6LayoutP12sizeThatFits8proposal8subviews5cache7CoreFou0G4SizeVAA012ProposedViewJ0V_AA0i10SubviewsJ0Vz1_QPtFTq"
    var sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) // -2 == RTLD_DEFAULT
    
    // If exact symbol doesn't resolve, try broader search
    if sym == nil {
        print("Exact symbol lookup failed, trying broader search for Layout.sizeThatFits descriptor")
        // TODO: Implement broader search if needed
        // For now, just report the failure
        if let err = dlerror() {
            let msg = String(cString: err)
            print("dlsym failed for \(symbol): \(msg)")
        }
    }
    
    return sym
}

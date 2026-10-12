import SwiftUI

/// `@State` without the macro.
///
/// Starting with the macOS 27 SDK, `@State` resolves to a macro implemented by the SwiftUIMacros compiler
/// plugin, which ships only with Xcode. Naming the underlying `State` property wrapper through this alias
/// keeps the views compiling with the Command Line Tools as well, with identical behaviour.
/// (`@Query` is likewise a macro; views use `Query` as a plain `DynamicProperty` instead.)
typealias ViewState<Value> = SwiftUI.State<Value>

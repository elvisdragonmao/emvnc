// Entry point of the Xcode app target. The app itself lives in the EmVNCUI library
// (Packages/EmVNCKit) so `swift build` and Xcode build exactly the same code.
import EmVNCUI

@main
struct EmVNCMain {
    static func main() {
        EmVNCApp.main()
    }
}

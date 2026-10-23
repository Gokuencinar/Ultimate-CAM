import Foundation

struct ProcessingOptions {
    var nightStatic = false
    var chooseSharpestReference = true
    var rejectMotion = true
    var maximumDimension: Double = 2560
    var noiseReduction: Double = 0
    var sharpening: Double = 0
    var liftShadows: Double = 0
}

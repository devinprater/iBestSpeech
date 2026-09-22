import CoreAudioKit
import AVFoundation

/// The extension's principal class.
///
/// A speech synthesis provider is an Audio Unit extension, so the class named in
/// `NSExtensionPrincipalClass` must be a factory that *vends* the audio unit —
/// not the audio unit itself. Pointing the plist straight at the
/// `AVSpeechSynthesisProviderAudioUnit` subclass meant the system never got a
/// factory, the extension never loaded, and no voices were ever listed.
///
/// This is `AUAudioUnitFactory`; the unit it returns is `OpenBSTSpeechProvider`.
public class AudioUnitFactory: NSObject, AUAudioUnitFactory {

    private var unit: AUAudioUnit?

    public func beginRequest(with context: NSExtensionContext) {
        // Nothing to do: speech requests arrive through the audio unit.
    }

    @objc
    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let created = try OpenBSTSpeechProvider(componentDescription: componentDescription,
                                                options: [])
        unit = created
        return created
    }
}

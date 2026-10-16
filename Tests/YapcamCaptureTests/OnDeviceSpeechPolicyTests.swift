import Foundation
import Speech
import Testing
@testable import YapcamCapture

@Suite struct OnDeviceSpeechPolicyTests {
    @Test func authorizationFailuresAreActionableAndNeverRequestPermission() throws {
        #expect(throws: TranscriptionError.authorizationRequired) { try OnDeviceSpeechPolicy.authorize(.notDetermined) }
        #expect(throws: TranscriptionError.authorizationDenied) { try OnDeviceSpeechPolicy.authorize(.denied) }
        try OnDeviceSpeechPolicy.authorize(.granted)
        #expect(!(TranscriptionError.authorizationRequired.errorDescription ?? "").isEmpty)
        #expect(!(TranscriptionError.authorizationDenied.errorDescription ?? "").isEmpty)
    }

    @Test func localeMatchingNeverFallsBackToAnotherLanguage() throws {
        let supported: Set<Locale> = [Locale(identifier: "de_DE"), Locale(identifier: "en_US")]
        #expect(try OnDeviceSpeechPolicy.locale("DE-de", supported: supported).identifier == "de_DE")
        #expect(try OnDeviceSpeechPolicy.locale("en-US", supported: supported).identifier == "en_US")
        for identifier in ["zz-ZZ", "de-AT", "", "en"] {
            #expect(throws: TranscriptionError.unsupportedLocale(identifier)) {
                try OnDeviceSpeechPolicy.locale(identifier, supported: supported)
            }
        }
    }

    @Test(arguments: [false, true], [false, true]) func missingLocalModelsOrUnavailableServiceNeverUseServer(supported: Bool, available: Bool) throws {
        if supported && available {
            let request = try OnDeviceSpeechPolicy.request(locale: "de-DE", supportsOnDevice: supported, available: available)
            #expect(request.requiresOnDeviceRecognition)
            #expect(request.shouldReportPartialResults)
            #expect(request.taskHint == .dictation)
        } else {
            #expect(throws: TranscriptionError.onDeviceUnavailable("de-DE")) {
                try OnDeviceSpeechPolicy.request(locale: "de-DE", supportsOnDevice: supported, available: available)
            }
        }
    }

    @Test func unavailableMessagesIdentifyTheRequestedLanguage() {
        #expect(TranscriptionError.onDeviceUnavailable("de-DE").errorDescription?.contains("de-DE") == true)
        #expect(TranscriptionError.timedOut.errorDescription?.contains("timed out") == true)
    }
    @Test func keytermsReachEveryNativeWindowWithoutLeakingIntoTheNextRequest() throws {
        let terms = ["Yapcam", "Clara Weiß", "forty two"]
        for _ in 0..<3 {
            let request = try OnDeviceSpeechPolicy.request(locale: "de-DE", supportsOnDevice: true, available: true, keyterms: terms)
            #expect(request.contextualStrings == terms)
            #expect(request.requiresOnDeviceRecognition)
        }
        let next = try OnDeviceSpeechPolicy.request(locale: "de-DE", supportsOnDevice: true, available: true)
        #expect(next.contextualStrings.isEmpty)
    }

    @Test func onlyDocumentedMissingAssetsErrorBecomesModelNotInstalled() {
        let missing = NSError(domain: "kLSRErrorDomain", code: 102)
        #expect(OnDeviceSpeechPolicy.recognitionError(missing, locale: "de-DE") as? TranscriptionError == .onDeviceModelNotInstalled("de-DE"))
        for native in [NSError(domain: "OtherDomain", code: 102), NSError(domain: "kLSRErrorDomain", code: 300),
                       NSError(domain: "kAFAssistantErrorDomain", code: 1101), NSError(domain: "kAFAssistantErrorDomain", code: 1110)] {
            let mapped = OnDeviceSpeechPolicy.recognitionError(native, locale: "de-DE") as NSError
            #expect(mapped.domain == native.domain && mapped.code == native.code)
        }
        #expect(OnDeviceSpeechPolicy.recognitionError(CancellationError(), locale: "de-DE") is CancellationError)
        #expect(TranscriptionError.unsupportedLocale("zz-ZZ").errorDescription?.contains("zz-ZZ") == true)
        #expect(TranscriptionError.onDeviceModelNotInstalled("de-DE").errorDescription?.contains("not installed") == true)
    }

}

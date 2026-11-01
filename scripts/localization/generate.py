import json
from pathlib import Path
base=Path(__file__).resolve().parents[2]
zh=json.loads((base/'shared/zh-Hans.json').read_text());en=json.loads((base/'shared/en.json').read_text())
assert set(zh)==set(en)
for k,v in en.items():
    assert k.count('%@')==v.count('%@'),(k,v)
    assert not any('\u3400'<=c<='\u9fff' for c in v),v
# Swift and C# see the same logical newline characters.
zh={k.replace('\\n','\n'):v.replace('\\n','\n') for k,v in zh.items()}
en={k.replace('\\n','\n'):v.replace('\\n','\n') for k,v in en.items()}
for name,data in [('zh-Hans',zh),('en',en)]:
    (base/f'shared/{name}.json').write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
pairs=',\n'.join('        '+json.dumps(k,ensure_ascii=False)+': '+json.dumps(v,ensure_ascii=False) for k,v in en.items())
(base/'FocusDesk/Models/AppLanguage.swift').write_text('''// Generated from shared/en.json by scripts/localization/generate.py.
import Foundation

enum AppLanguage: String, CaseIterable {
    case chinese = "zh-Hans", english = "en"
    static var current: AppLanguage = .chinese
    var title: String { self == .english ? "English" : "简体中文" }
    static var packagedDefault: AppLanguage {
        if let override = ProcessInfo.processInfo.environment["FOCUSDESK_LANGUAGE"], let language = AppLanguage(rawValue: override) { return language }
        return AppLanguage(rawValue: Bundle.main.infoDictionary?["FocusDeskDefaultLanguage"] as? String ?? "") ?? .chinese
    }
    static let translations: [String: String] = [
'''+pairs+'''
    ]
}

func L(_ key: String, _ arguments: String...) -> String {
    var result = AppLanguage.current == .english ? (AppLanguage.english[key] ?? key) : key
    let parts = result.components(separatedBy: "%@")
    result = parts.enumerated().map { index, part in
        part + (index < parts.count - 1 ? (index < arguments.count ? arguments[index] : "%@") : "")
    }.joined()

    return result
}
'''.replace('static let translations:', 'static let translations:').replace('AppLanguage.english[key]', 'AppLanguage.translations[key]'))
print(f'Validated {len(en)} complete translations')

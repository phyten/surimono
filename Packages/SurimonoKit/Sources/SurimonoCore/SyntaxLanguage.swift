import Foundation

// Language differences stay in data so every lexer shares the same escaping and progress guarantees.
struct SyntaxLanguage: Sendable {
    let id: String
    var keywords: Set<String> = []
    var types: Set<String> = []
    var builtins: Set<String> = []
    var literals: Set<String> = []
    var lineComments: [String] = []
    var blockComments: [(open: String, close: String)] = []
    var nestedComments = false
    var capitalizedTypes = false
    var decorators = false
    var preprocessor = false

    static let aliases: [String: String] = {
        let groups = [
            "swift", "javascript js jsx mjs cjs node", "typescript ts tsx mts cts", "python py python3",
            "ruby rb", "go golang", "rust rs", "java", "kotlin kt kts", "c h", "cpp c++ cc cxx hpp hh hxx",
            "csharp cs c#", "objectivec objc objective-c m mm", "php", "shell sh bash zsh console shellsession",
            "json jsonc json5", "yaml yml", "toml", "ini cfg conf properties", "html htm xhtml vue svelte",
            "xml svg plist xsl rss atom", "css scss less", "sql mysql postgresql postgres psql sqlite",
            "dockerfile docker", "makefile make mk", "diff patch", "lua",
        ]
        var result: [String: String] = [:]
        for group in groups {
            let names = group.split(separator: " ").map(String.init)
            guard let canonical = names.first else { continue }
            for name in names { result[name] = canonical }
        }
        return result
    }()

    static func definition(_ id: String) -> Self {
        var language = Self(id: id)
        func words(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }
        let cFamily = [
            "swift", "javascript", "typescript", "go", "rust", "java", "kotlin", "c", "cpp", "csharp", "objectivec",
            "php", "json", "css",
        ]
        if cFamily.contains(id) {
            language.lineComments = ["//"]
            language.blockComments = [("/*", "*/")]
        }
        if ["python", "ruby", "shell", "yaml", "toml", "ini", "dockerfile", "makefile", "php"].contains(id) {
            language.lineComments.append("#")
        }
        if ["toml", "ini"].contains(id) { language.lineComments.append(";") }
        if ["sql", "lua"].contains(id) { language.lineComments = ["--"] }
        if id == "sql" { language.blockComments = [("/*", "*/")] }
        if id == "lua" { language.blockComments = [("--[[", "]]")] }
        if id == "css" { language.lineComments = [] }
        language.nestedComments = ["swift", "rust"].contains(id)
        language.capitalizedTypes = ["swift", "kotlin", "java", "csharp", "typescript", "rust", "objectivec", "cpp"]
            .contains(id)
        language.decorators = ["swift", "java", "kotlin", "python", "typescript", "objectivec"].contains(id)
        language.preprocessor = ["c", "cpp", "objectivec", "csharp"].contains(id)
        switch id {
        case "swift", "ruby", "go", "lua": language.literals = words("true false nil")
        case "javascript", "typescript": language.literals = words("true false null undefined NaN Infinity")
        case "python": language.literals = words("True False None")
        case "rust": language.literals = words("true false None")
        case "c", "cpp": language.literals = words("true false NULL nullptr")
        case "objectivec": language.literals = words("true false nil Nil NULL YES NO")
        case "php": language.literals = words("true false null TRUE FALSE NULL")
        case "toml": language.literals = words("true false")
        case "ini": language.literals = words("true false yes no on off")
        default: language.literals = words("true false null")
        }
        var keywords = ""
        var types = ""
        var builtins = ""
        switch id {
        case "swift":
            keywords =
                "actor associatedtype async await as break case catch class continue convenience default defer deinit didSet do dynamic else enum extension fallthrough fileprivate final for func get guard if import in indirect infix init inout internal is isolated lazy let mutating nonisolated open operator optional override package postfix precedencegroup prefix private protocol public repeat required rethrows return self Self set some static struct subscript super switch throws throw try typealias var weak where while willSet"
            types =
                "Int Int8 Int16 Int32 Int64 UInt Float Double Bool String Character Array Dictionary Set Optional Result Void Any AnyObject"
            builtins = "print debugPrint dump assert precondition fatalError min max abs zip stride"
        case "javascript", "typescript":
            keywords =
                "as async await break case catch class const continue debugger declare default delete do else enum export extends finally for from function get if implements import in instanceof interface keyof let namespace new of private protected public readonly return set static super switch this throw try type typeof var void while with yield"
            types =
                "string number boolean any never unknown bigint symbol object Array Promise Map Set Date RegExp Error"
            builtins = "console JSON Math parseInt parseFloat isNaN setTimeout setInterval require fetch"
        case "python":
            keywords =
                "and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try while with yield"
            types = "int float str bool list dict tuple set bytes object"
            builtins = "print len range enumerate zip map filter open sum min max sorted isinstance super input"
        case "ruby":
            keywords =
                "alias and begin break case class def defined do else elsif end ensure for if in module next not or redo rescue retry return self super then undef unless until when while yield"
            builtins = "puts print p require require_relative attr_reader attr_writer attr_accessor raise lambda proc"
        case "go":
            keywords =
                "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var"
            types =
                "bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr"
            builtins = "append cap close copy delete len make new panic print println recover"
        case "rust":
            keywords =
                "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while"
            types = "bool char str String i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 Vec Option Result"
            builtins = "println print format vec panic assert Some Ok Err"
        case "java", "kotlin", "csharp":
            keywords =
                "abstract actual as async await base break case catch checked class const continue data default delegate do else enum event expect extends external final finally fixed for fun get if implements import in inline instanceof interface internal is lock namespace native new object open operator out override package params partial private protected public readonly record ref reified return sealed set sizeof stackalloc static struct super suspend switch synchronized this throw throws transient try typealias typeof unchecked unsafe using val var virtual void volatile when where while yield"
            types =
                "bool boolean byte char decimal double float int long object sbyte short string uint ulong ushort Int Long Double Float Boolean String Unit Void List Map Task"
            builtins = "println print System Console Math"
        case "c", "cpp", "objectivec":
            keywords =
                "alignas alignof asm auto break case catch class const constexpr consteval constinit continue default delete do else enum explicit export extern for friend goto if inline mutable namespace new noexcept operator private protected public register reinterpret_cast return signed sizeof static static_assert static_cast struct switch template this thread_local throw try typedef typename union unsigned using virtual volatile while id self super"
            types = "bool char double float int long short void size_t wchar_t NSString NSObject NSInteger BOOL"
            builtins = "printf fprintf scanf malloc calloc realloc free memcpy memset strlen sizeof"
        case "php":
            keywords =
                "abstract and as break callable case catch class clone const continue declare default do echo else elseif empty endfor endforeach endif endwhile eval exit extends final finally fn for foreach function global if implements include include_once instanceof interface isset list match namespace new or print private protected public require require_once return static switch throw trait try unset use var while xor yield"
            types = "array bool float int mixed object string void"
            builtins = "count strlen array_map explode implode json_encode json_decode"
        case "shell":
            keywords =
                "if then else elif fi for while until do done case esac function in return export local readonly select"
            builtins =
                "echo cd printf read test source alias set unset exit trap eval exec cat ls grep sed awk pwd mkdir rm cp mv touch"
        case "sql":
            keywords =
                "select from where insert into values update set delete create alter drop table index view join inner outer left right full cross on as and or not null is in exists between like group by having order asc desc limit offset union all distinct primary key foreign references constraint default begin commit rollback with recursive case when then else end returning count sum avg min max"
            types =
                "int integer bigint smallint numeric decimal real float double boolean text varchar char date time timestamp blob"
        case "dockerfile":
            keywords =
                "from run cmd copy add env arg workdir expose entrypoint user volume label healthcheck shell onbuild stopsignal maintainer"
        case "makefile":
            keywords = "ifeq ifneq ifdef ifndef else endif include define endef export override"
        case "lua":
            keywords =
                "and break do else elseif end for function goto if in local not or repeat return then until while"
            builtins = "print pairs ipairs next type tostring tonumber require assert error pcall select setmetatable"
        case "yaml": language.literals = words("true false yes no null ~")
        default: break
        }
        language.keywords = words(keywords)
        language.types = words(types)
        language.builtins = words(builtins)
        return language
    }
}

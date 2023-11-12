struct Value: CustomStringConvertible {
    let type: ValueType
    let data: Any

    var description: String { type.dump(self) }
    var toBool: Bool { type.toBool(self) }
    
    init(_ type: ValueType, _ data: Any) {
        self.type = type
        self.data = data
    }

    func identifierEmit(_ vm: VM, at pos: Position,
                        inNamespace ns: Namespace, withArguments args: inout [Form],
                        options opts: Set<EmitOption>) throws {
        try self.type.identifierEmit(self, vm, at: pos, inNamespace: ns, withArguments: &args, options: opts)
    }
}

class ValueType: CustomStringConvertible {
    let name: String
    var description: String { name }
    
    init(_ name: String) {
        self.name = name
    }

    func dump(_ value: Value) -> String {
        "\(value.data)"        
    }

    func identifierEmit(_ value: Value, _ vm: VM, at: Position,
                        inNamespace: Namespace, withArguments: inout [Form],
                        options: Set<EmitOption>) throws {
        vm.emit(.push(value))
    }

    func toBool(_ value: Value) -> Bool {
        true
    }
}

enum EmitError: Error {
    case missingArgument(Position)
    case unknownIdentifier(Position, String)
}

enum EvalError: Error {
    case missingValue(Position)
}

enum ReadError: Error {
    case openList(Position)
    case openString(Position)
}

typealias PC = Int

struct Function: CustomStringConvertible {
    class Call {
        let parentCall: Call?
        let returnPc: PC

        var position: Position
        var stackOffset: Int
        var target: Function
        
        init(_ parentCall: Call?, _ target: Function, at pos: Position, stackOffset: Int, returnPc: PC) {
            self.parentCall = parentCall
            self.target = target
            self.position = pos
            self.stackOffset = stackOffset
            self.returnPc = returnPc
        }
    }

    typealias Body = (Function, VM) throws -> Void
    
    let arguments: [String]
    let body: Body
    let name: String
    let startPc: PC?

    var description: String { name }
    
    init(_ name: String, _ arguments: [String], startPc: PC? = nil, _ body: @escaping Body) {
        self.name = name
        self.arguments = arguments
        self.startPc = startPc
        self.body = body
    }

    func call(_ vm: VM, at pos: Position) throws {
        if vm.stack.count < arguments.count {
            throw EvalError.missingValue(pos)
        }
        
        try body(self, vm)
    }
}

struct Macro: CustomStringConvertible {
    typealias Body = (Macro, VM, Position, Namespace, inout [Form]) throws -> Void
    
    let name: String
    let body: Body

    var description: String { name }
    
    init(_ name: String, _ body: @escaping Body) {
        self.name = name
        self.body = body
    }

    func emit(_ vm: VM, at pos: Position, inNamespace ns: Namespace, withArguments args: inout [Form]) throws {
        try body(self, vm, pos, ns, &args)
    }
}

class Namespace {
    let parent: Namespace?
    var bindings: [String:Value] = [:]
    
    subscript(key: String) -> Value? {
        get {
            return if let value = bindings[key] {
                value
            } else if parent != nil {
                parent![key]
            } else {
                nil
            }
        }
        set(value) { bindings[key] = value }
    }

    init(_ parent: Namespace? = nil) {
        self.parent = parent
    }
}

struct Position: CustomStringConvertible {
    let source: String

    var column: Int
    var description: String { "\(source)@\(line):\(column)" }
    var line: Int

    init(_ source: String, line: Int = 1, column: Int = 0) {
        self.source = source
        self.line = line
        self.column = column
    }
}

enum EmitOption  {
    case returning
}

protocol Form: CustomStringConvertible {
    var position: Position {get}
    func emit(_ vm: VM, inNamespace: Namespace, withArguments: inout [Form], options: Set<EmitOption>) throws
}

class BasicForm {
    let position: Position
    var description: String { "\(self)" }

    init(_ position: Position) {
        self.position = position
    }
}

class Identifier: BasicForm, Form {    
    let name: String
    override var description: String { name }
    
    init(_ position: Position, _ name: String) {
        self.name = name
        super.init(position)
    }

    func emit(_ vm: VM,
              inNamespace ns: Namespace, withArguments args: inout [Form], options opts: Set<EmitOption>) throws {
        if let value = ns[name] {
            try value.identifierEmit(vm, at: position, inNamespace: ns, withArguments: &args, options: opts)
        } else {
            throw EmitError.unknownIdentifier(position, name)
        }
    }
}

class List: BasicForm, Form {
    let items: [Form]
    override var description: String { "(\(items.map({"\($0)"}).joined(separator: " "))" }

    init(_ position: Position, _ items: [Form]) {
        self.items = items
        super.init(position)
    }

    func emit(_ vm: VM,
              inNamespace ns: Namespace, withArguments args: inout [Form], options opts: Set<EmitOption>) throws {
        try items.emit(vm, inNamespace: ns, options: opts)
    }
}

class Literal: BasicForm, Form {
    let value: Value
    override var description: String { "\(value)" }

    init(_ position: Position, _ value: Value) {
        self.value = value
        super.init(position)
    }

    func emit(_ vm: VM,
              inNamespace ns: Namespace, withArguments args: inout [Form], options: Set<EmitOption>) throws {
        vm.emit(.push(value))
    }
}

extension [Form] {
    func emit(_ vm: VM, inNamespace ns: Namespace, options: Set<EmitOption>) throws {
        var fs = self
        
        while fs.count > 0 {
            try fs.removeFirst().emit(vm, inNamespace: ns, withArguments: &fs, options: options)
        }
    }
}

enum Op {
    case argument(Int)
    case benchmark(Position)
    case branch(Position, PC)
    case call(Position, Function)
    case goto(PC)
    case nop
    case or(Position, PC)
    case popCall(Function)
    case push(Value)
    case stop
    case tailCall(Position, Function)
    case task(PC)
    case trace
}

typealias Stack = [Value]

class Task {
    typealias Id = Int

    let id: Id

    var currentCall: Function.Call?
    var pc: PC
    var stack: Stack = []

    init(id: Id, startPc: PC) {
        self.id = id
        self.pc = startPc
    }
}

class VM {        
    var code: [Op] = []

    var currentCall: Function.Call? {
        get {currentTask!.currentCall}
        set(v) {currentTask!.currentCall = v} 
    }

    var currentTask: Task? {tasks[0]}
    var emitPc: PC {code.count}
    var nextTaskId = 0

    var pc: PC {
        get {currentTask!.pc}
        set(pc) {currentTask!.pc = pc}
    }

    var stack: Stack {
        get {currentTask!.stack}
        set(v) {currentTask!.stack = v}
    }
    
    var tasks: [Task] = []
    var trace = false
    
    init() {
        startTask()
    }
    
    @discardableResult
    func emit(_ op: Op) -> PC {
        if trace { code.append(.trace) }
        let pc = code.count
        code.append(op)
        return pc
    }
    
    func eval(fromPc: PC) throws {
        pc = fromPc
        
        loop: while true {
            let op = code[pc]
            
            switch op {
            case let.argument(index):
                vm.push(vm.stack[vm.currentCall!.stackOffset+index])
                pc += 1
            case let .benchmark(pos):
                if stack.isEmpty {
                    throw EvalError.missingValue(pos)
                }

                let n = pop()

                let t = try ContinuousClock().measure {
                    pc += 1
                    let startPc = pc
                    let stackLength = stack.count
                    
                    for _ in 0..<(n.data as! Int) {
                        try eval(fromPc: startPc)
                        stack.removeLast(stack.count - stackLength)
                    }
                }

                push(Value(timeType, t))
            case let .call(pos, target):
                pc += 1
                try target.call(self, at: pos)
            case let .goto(targetPc):
                pc = targetPc
            case let .branch(pos, elsePc):
                if stack.isEmpty {
                    throw EvalError.missingValue(pos)
                }

                if pop().toBool {
                    pc += 1
                } else {
                    pc = elsePc
                }
            case .nop:
                pc += 1
            case let .or(pos, endPc):
                if let l = peek() {
                    if l.toBool {
                        pc = endPc
                    } else {
                        _ = pop()
                        pc += 1
                    }
                } else {
                    throw EvalError.missingValue(pos)
                }
            case let .popCall(target):
                let c = vm.currentCall!
                vm.currentCall = c.parentCall
                vm.stack.removeSubrange(c.stackOffset..<c.stackOffset+target.arguments.count)
                pc = c.returnPc
            case let .push(value):
                push(value)
                pc += 1
            case .stop:
                break loop
            case let .tailCall(pos, target):
                let c = vm.currentCall
                
                if c == nil || c!.target.startPc == nil {
                    pc += 1
                    try target.call(self, at: pos)
                } else {
                    c!.target = target
                    c!.position = pos
                    c!.stackOffset = vm.stack.count - target.arguments.count
                    pc = target.startPc!
                }
            case let .task(endPc):
                startTask(pc: pc+1)
                pc = endPc
            case .trace:
                pc += 1
                print("\(pc) \(code[pc])")
            }
        }
    }

    func peek() -> Value? {
        currentTask!.stack.last
    }

    func pop() -> Value {
        currentTask!.stack.removeLast()
    }

    func push(_ value: Value) {
        currentTask!.stack.append(value)
    }

    func startTask(pc: PC = 0) {
        let t = Task(id: nextTaskId, startPc: pc)
        tasks.append(t)
        nextTaskId += 1
    }
}

struct Input {
    var data: String

    init(_ data: String = "") {
        self.data = data
    }

    mutating func append(_ data: String) {
        self.data.append(data)
    }
    
    func peekChar() -> Character? {
        return data.first
    }
    
    mutating func popChar() -> Character? {
        data.isEmpty ? nil : data.removeFirst()
    }

    mutating func pushChar(_ char: Character) {
        data.insert(char, at: data.startIndex)
    }

    mutating func reset() {
        data = ""
    }
}

typealias Reader = (_ input: inout Input, _ pos: inout Position) throws -> Form?

let readers = [readWhitespace, readInt, readList, readString, readIdentifier]

func readForm(_ input: inout Input, _ pos: inout Position) throws -> Form? {
    for r in readers {
        if let f = try r(&input, &pos) {
            return f
        }
    }

    return nil
}

func readForms(_ reader: Reader, _ input: inout Input, _ pos: inout Position) throws -> [Form] {
    var output: [Form] = []
    
    while let f = try reader(&input, &pos) {
        output.append(f)
    }

    return output
}

func readIdentifier(_ input: inout Input, _ pos: inout Position) throws -> Form? {
    let fpos = pos
    var name = ""
    
    while let c = input.popChar() {
        if c.isWhitespace || c == "(" || c == ")" {
            input.pushChar(c)
            break
        }
        
        name.append(c)
        pos.column += 1
    }
    
    return (name.count == 0) ? nil : Identifier(fpos, name)
}

func readInt(_ input: inout Input, _ pos: inout Position) throws -> Form? {
    let fpos = pos
    var v = 0
    var neg = false
    
    let c = input.popChar()
    if c == nil { return nil }
    
    if c == "-" {
        if let c = input.popChar() {
            if c.isNumber {
                neg = true
            } else {
                input.pushChar(c)
                input.pushChar("-")
            }
        }
    } else {
        input.pushChar(c!)
    }
    
    while let c = input.popChar() {
        if !c.isNumber {
            input.pushChar(c)
            break
        }
        
        v *= 10
        v += c.hexDigitValue!
        pos.column += 1
    }
    
    return (pos.column == fpos.column) ? nil : Literal(fpos, Value(intType, neg ? -v : v))
}

func readList(_ input: inout Input, _ pos: inout Position) throws -> Form? {
    let fpos = pos
    var c = input.popChar()
    
    if c != "(" {
        if c != nil { input.pushChar(c!) }
        return nil
    }
    
    pos.column += 1
    var items: [Form] = []

    while true {
        _ = try readWhitespace(&input, &pos)
        c = input.popChar()
        if c == nil || c == ")" { break }
        input.pushChar(c!)

        if let f = try readForm(&input, &pos) {
            items.append(f)
        } else {
            break
        }
    }

    if c != ")" { throw ReadError.openList(fpos) }
    pos.column += 1
    
    return List(fpos, items)
}

func readString(_ input: inout Input, _ pos: inout Position) throws -> Form? {
    let fpos = pos
    var c = input.popChar()
    
    if c != "\"" {
        if c != nil { input.pushChar(c!) }
        return nil
    }
    
    pos.column += 1
    var body: [Character] = []

    while true {
        c = input.popChar()
        if c == nil || c == "\"" { break }
        body.append(c!)
    }

    if c != "\"" { throw ReadError.openString(fpos) }
    pos.column += 1
    return Literal(fpos, Value(stringType, String(body)))
}

func readWhitespace(_ input: inout Input, _ pos: inout Position) throws -> Form? {
    while let c = input.popChar() {
        if c.isNewline {
            pos.line += 1
        } else if c.isWhitespace {
            pos.column += 1
        } else {
            input.pushChar(c)
            break
        }
    }
    
    return nil
}

let stdLib = Namespace()

func stdFunction(_ name: String, _ args: [String], _ body: @escaping Function.Body) {
    stdLib[name] = Value(functionType, Function(name, args, body))
}

func stdMacro(_ name: String, _ body: @escaping Macro.Body) {
    stdLib[name] = Value(macroType, Macro(name, body))
}

class ArgumentType: ValueType {
    init() {
        super.init("Argument")
    }

    override func identifierEmit(_ value: Value, _ vm: VM, at pos: Position,
                                 inNamespace ns: Namespace, withArguments args: inout [Form],
                                 options: Set<EmitOption>) throws {
        vm.emit(.argument(value.data as! Int))
    }
}

let argumentType = ArgumentType()

class BoolType: ValueType {
    init() {
        super.init("Bool")
    }

    override func toBool(_ value: Value) -> Bool {
        value.data as! Bool
    }
}

let boolType = BoolType()
stdLib["Bool"] = Value(metaType, boolType)
stdLib["true"] = Value(boolType, true)
stdLib["false"] = Value(boolType, false)

class FunctionType: ValueType {
    init() {
        super.init("Function")
    }

    override func identifierEmit(_ value: Value, _ vm: VM, at pos: Position,
                                 inNamespace ns: Namespace, withArguments args: inout [Form],
                                 options opts: Set<EmitOption>) throws {
        let f = value.data as! Function
        
        for _ in 0..<f.arguments.count {
            if args.isEmpty {
                throw EmitError.missingArgument(pos)
            }

            try args.removeFirst().emit(vm, inNamespace: ns, withArguments: &args, options: [])
        }

        if opts.contains(.returning) && f.startPc != nil {
            vm.emit(.tailCall(pos, f))
        } else {
            vm.emit(.call(pos, f))
        }
    }
}

let functionType = FunctionType()
stdLib["Function"] = Value(metaType, functionType)

class IntType: ValueType {
    init() {
        super.init("Int")
    }

    override func toBool(_ value: Value) -> Bool {
        (value.data as! Int) != 0
    }
}

let intType = IntType()
stdLib["Int"] = Value(metaType, intType)

class MacroType: ValueType {
    init() {
        super.init("Macro")
    }

    override func identifierEmit(_ value: Value, _ vm: VM, at pos: Position,
                                 inNamespace ns: Namespace, withArguments args: inout [Form],
                                 options: Set<EmitOption>) throws {
        try (value.data as! Macro).emit(vm, at: pos, inNamespace: ns, withArguments: &args)
    }
}

let macroType = MacroType()
stdLib["Macro"] = Value(metaType, macroType)

let metaType = ValueType("Meta")
stdLib["Meta"] = Value(metaType, metaType)

class StringType: ValueType {
    init() {
        super.init("String")
    }

    override func toBool(_ value: Value) -> Bool {
        (value.data as! String).count != 0
    }
}

let stringType = StringType()
stdLib["String"] = Value(metaType, stringType)

class TimeType: ValueType {
    init() {
        super.init("Time")
    }

    override func toBool(_ value: Value) -> Bool {
        (value.data as! Duration) != Duration.zero
    }
}

let timeType = TimeType()
stdLib["Time"] = Value(metaType, timeType)

stdMacro("benchmark") {(_, vm, pos, ns, args) throws in
    try args.removeFirst().emit(vm, inNamespace: ns, withArguments: &args, options: [])
    vm.emit(.benchmark(pos))
    try args.removeFirst().emit(vm, inNamespace: ns, withArguments: &args, options: [])
    vm.emit(.stop)
}

stdMacro("function") {(_, vm, pos, ns, args) throws in
    let id = (args.removeFirst() as! Identifier).name
    let fargs = (args.removeFirst() as! List).items.map {($0 as! Identifier).name}
    let body = args.removeFirst()
    let skip = vm.emit(.nop)
    let startPc = vm.emitPc

    let f = Function(id, fargs, startPc: startPc) {(f, vm) throws in
        vm.currentCall = Function.Call(vm.currentCall, f,
                                       at: pos, stackOffset: vm.stack.count-fargs.count, returnPc: vm.pc)
        vm.pc = startPc
    }

    ns[id] = Value(functionType, f)
    let fns = Namespace(ns)

    for i in 0..<fargs.count {
        fns[fargs[i]] = Value(argumentType, i)
    }

    try body.emit(vm, inNamespace: fns, withArguments: &args, options: [])
    vm.emit(.popCall(f))
    vm.code[skip] = .goto(vm.emitPc)
}

stdMacro("if") {(_, vm, pos, ns, args) throws in
    try args.removeFirst().emit(vm, inNamespace: ns, withArguments: &args, options: [])
    let ifPc = vm.emit(.nop)
    try args.removeFirst().emit(vm, inNamespace: ns, withArguments: &args, options: [])
    var elsePc = vm.emitPc

    if !args.isEmpty {
        if let next = args.first as? Identifier {
            if next.name == "else" {
                _ = args.removeFirst()
                let skipPc = vm.emit(.nop)
                elsePc = vm.emitPc
                try args.removeFirst().emit(vm, inNamespace: ns, withArguments: &args, options: [])
                vm.code[skipPc] = .goto(vm.emitPc)
            }
        }
    }

    vm.code[ifPc] = .branch(pos, elsePc)
}

stdMacro("or") {(_, vm, pos, ns, args) throws in
    try args.removeFirst().emit(vm, inNamespace: ns, withArguments: &args, options: [])
    let orPc = vm.emit(.nop)
    try args.removeFirst().emit(vm, inNamespace: ns, withArguments: &args, options: [])
    vm.code[orPc] = .or(pos, vm.emitPc)
}

stdMacro("return") {(_, vm, pos, ns, args) throws in
    try args.removeFirst().emit(vm, inNamespace: ns, withArguments: &args, options: [.returning])
}

stdMacro("trace") {(_, vm, pos, ns, args) throws in
    vm.trace = !vm.trace
}

stdMacro("task") {(_, vm, pos, ns, args) throws in
    let task = vm.emit(.nop)
    try args.removeFirst().emit(vm, inNamespace: ns, withArguments: &args, options: [])
    vm.emit(.stop)
    vm.code[task] = .task(vm.emitPc)
}

stdFunction("=", ["left", "right"]) {(_, vm) throws in
    let r = vm.pop()
    let l = vm.pop()
    vm.push(Value(boolType, (l.data as! Int) == (r.data as! Int)))
}

stdFunction("<", ["left", "right"]) {(_, vm) throws in
    let r = vm.pop()
    let l = vm.pop()
    vm.push(Value(boolType, (l.data as! Int) < (r.data as! Int)))
}

stdFunction(">", ["left", "right"]) {(_, vm) throws in
    let r = vm.pop()
    let l = vm.pop()
    vm.push(Value(boolType, (l.data as! Int) > (r.data as! Int)))
}

stdFunction("+", ["left", "right"]) {(_, vm) throws in
    let r = vm.pop()
    let l = vm.pop()
    vm.push(Value(intType, (l.data as! Int) + (r.data as! Int)))
}

stdFunction("-", ["left", "right"]) {(_, vm) throws in
    let r = vm.pop()
    let l = vm.pop()
    vm.push(Value(intType, (l.data as! Int) - (r.data as! Int)))
}

stdFunction("yield", []) {(_, vm) throws in
    vm.tasks.append(vm.tasks.removeFirst())
}

func repl(_ vm: VM, _ reader: Reader, inNamespace ns: Namespace) throws {
    var input = Input()
    var prompt = 1
    
    while true {
        print("\(prompt). ", terminator: "")
        let line = readLine(strippingNewline: false)
        
        if line == nil || line! == "\n" {
            do {
                var pos = Position("repl")
                let fs = try readForms(reader, &input, &pos)
                let pc = vm.emitPc
                try fs.emit(vm, inNamespace: ns, options: [])
                vm.emit(.stop)
                try vm.eval(fromPc: pc)
                print("\(vm.stack.isEmpty ? "_" : "\(vm.pop())")\n")
                input.reset()
            } catch {
                print("\(error)\n")
            }
            
            prompt = 1
        } else {
            input.append(line!)
            prompt += 1
        }
    }
}

let vm = VM()
try repl(vm, readForm, inNamespace: stdLib)

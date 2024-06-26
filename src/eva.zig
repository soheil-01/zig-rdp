const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Environment = @import("environment.zig").Environment;

pub const Eva = struct {
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    global: Environment,

    pub fn init(allocator: std.mem.Allocator) !Eva {
        var arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        const aa = arena.allocator();

        var global = Environment.init(aa, null);
        _ = try global.define("VERSION", EvalResult{ .String = "0.0.1" });
        _ = try global.define("print", EvalResult{ .Function = .{ .Native = .{ .Print = {} } } });

        return Eva{ .arena = arena, .allocator = aa, .global = global };
    }

    pub fn deinit(self: *Eva) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
    }

    pub const Error = error{ InvalidOperandTypes, ClassNotAnEnvironment, ConstructorNotFound, ComputedPropertyAccessNotSupported, InvalidObject } || Environment.Error || std.mem.Allocator.Error || std.fmt.AllocPrintError || std.fs.File.OpenError || std.fs.File.GetSeekPosError || std.fs.File.ReadError || Parser.Error || std.io.AnyWriter.Error;

    const NativeFunction = union(enum) {
        Print,

        fn call(self: NativeFunction, args: []EvalResult, allocator: std.mem.Allocator) !EvalResult {
            const stdout = std.io.getStdOut().writer();

            switch (self) {
                .Print => {
                    for (args, 0..) |arg, i| {
                        try stdout.print("{s}", .{try arg.toString(allocator)});
                        if (i < args.len - 1) {
                            try stdout.print(" ", .{});
                        }
                    }
                    try stdout.print("\n", .{});

                    return EvalResult{ .Null = {} };
                },
            }
        }
    };

    const UserDefinedFunction = struct {
        params: []Parser.Identifier,
        body: Parser.BlockStatement,
        env: *Environment,
    };

    const LambdaFunction = struct { params: []Parser.Identifier, body: Parser.LambdaExpressionBody, env: *Environment };

    const Function = union(enum) { Native: NativeFunction, UserDefined: UserDefinedFunction, Lambda: LambdaFunction };

    pub const EvalResult = union(enum) {
        Number: i64,
        String: []const u8,
        Null: void,
        Bool: bool,
        Function: Function,
        Return: ?*EvalResult,
        Env: *Environment,

        pub fn toString(self: EvalResult, allocator: std.mem.Allocator) ![]u8 {
            return switch (self) {
                .Number => |number| std.fmt.allocPrint(allocator, "{}", .{number}),
                .String => |string| std.fmt.allocPrint(allocator, "{s}", .{string}),
                .Null => std.fmt.allocPrint(allocator, "null", .{}),
                .Bool => |boolean| std.fmt.allocPrint(allocator, "{}", .{boolean}),
                .Function => std.fmt.allocPrint(allocator, "<fn>", .{}),
                .Env => std.fmt.allocPrint(allocator, "<env>", .{}),
                .Return => {
                    unreachable;
                },
            };
        }

        pub fn display(self: EvalResult, allocator: std.mem.Allocator) !void {
            const stdout = std.io.getStdOut().writer();

            const string = try self.toString(allocator);
            defer allocator.free(string);
            try stdout.print("{s}\n", .{string});
        }

        pub fn eql(self: EvalResult, other: EvalResult) !bool {
            return switch (self) {
                .Number => switch (other) {
                    .Number => self.Number == other.Number,
                    else => false,
                },
                .String => switch (other) {
                    .String => std.mem.eql(u8, self.String, other.String),
                    else => false,
                },
                .Null => switch (other) {
                    .Null => true,
                    else => false,
                },
                .Bool => switch (other) {
                    .Bool => self.Bool == other.Bool,
                    else => false,
                },
                else => Error.InvalidOperandTypes,
            };
        }
    };

    pub fn evalProgram(self: *Eva, program: Parser.Program) Error!EvalResult {
        var result = EvalResult{ .Null = {} };
        for (program.body) |statement| {
            result = try self.eval(statement, &self.global);
        }

        return result;
    }

    pub fn eval(self: *Eva, statement: Parser.Statement, env: *Environment) Error!EvalResult {
        return switch (statement) {
            .ExpressionStatement => |exprStmt| self.evalExpression(exprStmt.expression, env),
            .VariableStatement => |varStmt| self.evalVariableStatement(varStmt, env),
            .BlockStatement => |blockStmt| self.evalBlockStatement(blockStmt, env, true),
            .IfStatement => |ifStmt| self.evalIfStatement(ifStmt, env),
            .WhileStatement => |whileStmt| self.evalWhileStatement(whileStmt, env),
            .DoWhileStatement => |doWhileStmt| self.evalDoWhileStatement(doWhileStmt, env),
            .ForStatement => |forStmt| self.evalForStatement(forStmt, env),
            .EmptyStatement => EvalResult{ .Null = {} },
            .FunctionDeclaration => |functionDeclaration| self.evalFunctionDeclaration(functionDeclaration, env),
            .ReturnStatement => |returnStmt| self.evalReturnStatement(returnStmt, env),
            .SwitchStatement => |switchStmt| self.evalSwitchStatement(switchStmt, env),
            .ClassDeclaration => |classDeclaration| self.evalClassDeclaration(classDeclaration, env),
            .ModuleDeclaration => |moduleDeclaration| self.evalModuleDeclaration(moduleDeclaration, env),
        };
    }

    fn evalModuleDeclaration(self: *Eva, moduleDeclaration: Parser.ModuleDeclaration, env: *Environment) Error!EvalResult {
        const moduleEnv = try self.allocator.create(Environment);
        moduleEnv.* = Environment.init(self.allocator, env);

        _ = try self.evalBlockStatement(moduleDeclaration.body, moduleEnv, false);

        try env.define(moduleDeclaration.name.name, EvalResult{ .Env = moduleEnv });

        return EvalResult{ .Env = moduleEnv };
    }

    fn evalClassDeclaration(self: *Eva, classDeclaration: Parser.ClassDeclaration, env: *Environment) Error!EvalResult {
        var parentEnv: *Environment = undefined;
        if (classDeclaration.superClass) |superClass| {
            const result = try env.lookup(superClass.name);
            if (result != .Env) {
                return Error.ClassNotAnEnvironment;
            }
            parentEnv = result.Env;
        } else {
            parentEnv = env;
        }
        const classEnv = try self.allocator.create(Environment);
        classEnv.* = Environment.init(self.allocator, parentEnv);
        _ = try self.evalBlockStatement(classDeclaration.body, classEnv, false);

        try env.define(classDeclaration.id.name, EvalResult{ .Env = classEnv });

        return EvalResult{ .Null = {} };
    }

    fn evalSwitchStatement(self: *Eva, switchStmt: Parser.SwitchStatement, env: *Environment) Error!EvalResult {
        const discriminantResult = try self.evalExpression(switchStmt.discriminant, env);
        const defaultCase: ?Parser.SwitchCase = for (switchStmt.cases) |case| {
            if (case.testE == null) {
                break case;
            }
        } else null;

        for (switchStmt.cases) |case| {
            if (case.testE) |caseTestE| {
                const testEResult = try self.evalExpression(caseTestE, env);
                if (try discriminantResult.eql(testEResult)) {
                    _ = try self.evalBlockStatement(case.consequent, env, true);
                    return EvalResult{ .Null = {} };
                }
            }
        }

        if (defaultCase) |case| {
            _ = try self.evalBlockStatement(case.consequent, env, true);
        }

        return EvalResult{ .Null = {} };
    }

    fn evalReturnStatement(self: *Eva, returnStmt: Parser.ReturnStatement, env: *Environment) Error!EvalResult {
        var result = EvalResult{ .Return = null };
        if (returnStmt.argument) |argument| {
            var evalResult = try self.evalExpression(argument, env);
            result = EvalResult{ .Return = &evalResult };
        }

        return result;
    }

    fn evalFunctionDeclaration(self: *Eva, functionDeclaration: Parser.FunctionDeclaration, env: *Environment) Error!EvalResult {
        const function = UserDefinedFunction{ .params = functionDeclaration.params, .body = functionDeclaration.body, .env = try self.allocator.create(Environment) };
        function.env.* = env.*;
        try env.define(functionDeclaration.name.name, EvalResult{ .Function = .{ .UserDefined = function } });

        return EvalResult{ .Null = {} };
    }

    fn evalForStatement(self: *Eva, forStmt: Parser.ForStatement, env: *Environment) Error!EvalResult {
        var forEnv = Environment.init(self.allocator, env);

        if (forStmt.init) |initStmt| {
            _ = switch (initStmt) {
                .Expression => |exp| try self.evalExpression(exp, &forEnv),
                .VariableStatement => |variableStmt| try self.eval(Parser.Statement{ .VariableStatement = variableStmt }, &forEnv),
            };
        }

        var result = EvalResult{ .Null = {} };
        while (true) {
            if (forStmt.testE) |testE| {
                const testExpResult = try self.evalExpression(testE, &forEnv);
                if (testExpResult != .Bool or !testExpResult.Bool) {
                    break;
                }
            }

            result = try self.eval(forStmt.body.*, &forEnv);

            if (forStmt.update) |updateExp| {
                _ = try self.evalExpression(updateExp, &forEnv);
            }
        }

        return result;
    }

    fn evalDoWhileStatement(self: *Eva, doWhileStmt: Parser.DoWhileStatement, env: *Environment) Error!EvalResult {
        var result = try self.eval(doWhileStmt.body.*, env);

        while (true) {
            const testE = try self.evalExpression(doWhileStmt.testE, env);
            if (testE != .Bool or !testE.Bool) {
                break;
            }

            result = try self.eval(doWhileStmt.body.*, env);
        }

        return result;
    }

    fn evalWhileStatement(self: *Eva, whileStmt: Parser.WhileStatement, env: *Environment) Error!EvalResult {
        var result = EvalResult{ .Null = {} };

        while (true) {
            const testE = try self.evalExpression(whileStmt.testE, env);
            if (testE != .Bool or !testE.Bool) {
                break;
            }

            result = try self.eval(whileStmt.body.*, env);
        }

        return result;
    }

    fn evalIfStatement(self: *Eva, ifStmt: Parser.IfStatement, env: *Environment) Error!EvalResult {
        const testE = try self.evalExpression(ifStmt.testE, env);
        if (testE == .Bool and testE.Bool) {
            return self.eval(ifStmt.consequent.*, env);
        }

        if (ifStmt.alternate) |alternate| {
            return self.eval(alternate.*, env);
        }

        return EvalResult{ .Null = {} };
    }

    fn evalBlockStatement(self: *Eva, blockStmt: Parser.BlockStatement, env: *Environment, shouldCreateNewEnvironment: bool) Error!EvalResult {
        var blockEnv: *Environment = env;
        if (shouldCreateNewEnvironment) {
            blockEnv = try self.allocator.create(Environment);
            blockEnv.* = Environment.init(self.allocator, env);
        }

        var result = EvalResult{ .Null = {} };
        for (blockStmt.body) |stmt| {
            result = try self.eval(stmt, blockEnv);
        }

        return result;
    }

    fn evalVariableStatement(self: *Eva, varStmt: Parser.VariableStatement, env: *Environment) Error!EvalResult {
        for (varStmt.declarations) |declaration| {
            try env.define(declaration.id.name, if (declaration.init) |exp| try self.evalExpression(exp, env) else EvalResult{ .Null = {} });
        }

        return EvalResult{ .Null = {} };
    }

    fn evalExpression(self: *Eva, exp: Parser.Expression, env: *Environment) Error!EvalResult {
        return switch (exp) {
            .Literal => |literal| self.evalLiteral(literal),
            .BinaryExpression => |binaryExp| self.evalBinaryExpression(binaryExp, env),
            .Identifier => |identifier| env.lookup(identifier.name),
            .AssignmentExpression => |assignmentExp| self.evalAssignmentExpression(assignmentExp, env),
            .UnaryExpression => |unaryExp| self.evalUnaryExpression(unaryExp, env),
            .CallExpression => |callExp| self.evalCallExpression(callExp, env),
            .LambdaExpression => |lambdaExp| self.evalLambdaExpression(lambdaExp, env),
            .NewExpression => |newExp| self.evalNewExpression(newExp, env),
            .MemberExpression => |memberExp| self.evalMemberExpression(memberExp, env),
            .Super => |super| self.evalSuper(super, env),
            .LogicalExpression => |logicalExp| self.evalLogicalExpression(logicalExp, env),
            .Import => |import| self.evalImport(import),
        };
    }

    fn evalImport(self: *Eva, import: Parser.Import) Error!EvalResult {
        const fileName = try std.fmt.allocPrint(self.allocator, "src/modules/{s}.eva", .{import.name.value});

        const file = try std.fs.cwd().openFile(fileName, .{});
        defer file.close();

        const fileSize = try file.getEndPos();
        const codes = try self.allocator.alloc(u8, fileSize);
        _ = try file.read(codes);

        var parser = try Parser.init(self.allocator);
        defer parser.deinit();

        const program = try parser.parse(codes);

        const moduleDeclaration = Parser.ModuleDeclaration{ .name = Parser.Identifier{ .name = import.name.value }, .body = Parser.BlockStatement{ .body = program.body } };

        return self.evalModuleDeclaration(moduleDeclaration, &self.global);
    }

    fn evalLogicalExpression(self: *Eva, logicalExp: Parser.LogicalExpression, env: *Environment) Error!EvalResult {
        const left = try self.evalExpression(logicalExp.left.*, env);
        const right = try self.evalExpression(logicalExp.right.*, env);
        const operator = logicalExp.operator;

        if (left != .Bool or right != .Bool) {
            return Error.InvalidOperandTypes;
        }

        return switch (operator.type) {
            .LogicalOr => EvalResult{ .Bool = left.Bool or right.Bool },
            .LogicalAnd => EvalResult{ .Bool = left.Bool and right.Bool },
            else => {
                unreachable;
            },
        };
    }

    fn evalSuper(_: *Eva, super: Parser.Super, env: *Environment) Error!EvalResult {
        const envResult = try env.lookup(super.className.name);
        if (envResult != .Env) {
            return Error.ClassNotAnEnvironment;
        }
        if (envResult.Env.parent) |parentEnv| {
            return EvalResult{ .Env = parentEnv };
        }

        return Error.VariableIsNotDefined;
    }

    fn evalMemberExpression(self: *Eva, memberExp: Parser.MemberExpression, env: *Environment) Error!EvalResult {
        if (memberExp.computed) {
            return Error.ComputedPropertyAccessNotSupported;
        }
        const object = try self.evalExpression(memberExp.object.*, env);
        if (object != .Env) {
            return Error.InvalidObject;
        }
        const property = memberExp.property.Identifier;

        return object.Env.lookup(property.name);
    }

    fn evalNewExpression(self: *Eva, newExp: Parser.NewExpression, env: *Environment) Error!EvalResult {
        const classEnvResult = try self.evalExpression(newExp.callee.*, env);
        if (classEnvResult != .Env) {
            return Error.ClassNotAnEnvironment;
        }
        const classEnv = classEnvResult.Env;

        const newEnv = Environment.init(self.allocator, classEnv);
        const instanceEnvResult = EvalResult{ .Env = try self.allocator.create(Environment) };
        instanceEnvResult.Env.* = newEnv;

        const constructorFnResult = try classEnv.lookup("constructor");
        if (constructorFnResult != .Function) {
            return Error.ConstructorNotFound;
        }
        const constructorFn = constructorFnResult.Function.UserDefined;
        const args: []EvalResult = try std.mem.concat(self.allocator, EvalResult, &.{ &[_]EvalResult{instanceEnvResult}, try self.evalArgs(newExp.arguments, env) });

        _ = try self.callUserDefinedFunction(constructorFn, args);

        return instanceEnvResult;
    }

    fn evalLambdaExpression(self: *Eva, lambdaExp: Parser.LambdaExpression, env: *Environment) Error!EvalResult {
        const function = LambdaFunction{ .params = lambdaExp.params, .body = lambdaExp.body, .env = try self.allocator.create(Environment) };
        function.env.* = env.*;

        return EvalResult{ .Function = .{ .Lambda = function } };
    }

    fn evalCallExpression(self: *Eva, callExp: Parser.CallExpression, env: *Environment) Error!EvalResult {
        const callee = try self.evalExpression(callExp.callee.*, env);

        const evaluatedArgs = try self.evalArgs(callExp.arguments, env);

        if (callee != .Function) {
            return Error.VariableIsNotDefined;
        }

        switch (callee.Function) {
            .Native => |nativeFunc| {
                return try nativeFunc.call(evaluatedArgs, self.allocator);
            },
            .UserDefined => |userDefinedFunc| {
                return self.callUserDefinedFunction(userDefinedFunc, evaluatedArgs);
            },
            .Lambda => |lambdaFunc| {
                var activationEnv = Environment.init(self.allocator, lambdaFunc.env);
                for (lambdaFunc.params, 0..) |param, i| {
                    _ = try activationEnv.define(param.name, evaluatedArgs[i]);
                }

                return switch (lambdaFunc.body) {
                    .BlockStatement => self.evalFunctionBody(lambdaFunc.body.BlockStatement, &activationEnv),
                    .Expression => self.evalExpression(lambdaFunc.body.Expression.*, &activationEnv),
                };
            },
        }
    }

    fn evalArgs(self: *Eva, args: []Parser.Expression, env: *Environment) ![]EvalResult {
        var evaluatedArgs = std.ArrayList(EvalResult).init(self.allocator);
        for (args) |arg| {
            try evaluatedArgs.append(try self.evalExpression(arg, env));
        }

        return evaluatedArgs.toOwnedSlice();
    }

    fn callUserDefinedFunction(self: *Eva, userDefinedFunc: UserDefinedFunction, evaluatedArgs: []EvalResult) Error!EvalResult {
        var activationEnv = Environment.init(self.allocator, userDefinedFunc.env);
        for (userDefinedFunc.params, 0..) |param, i| {
            _ = try activationEnv.define(param.name, evaluatedArgs[i]);
        }

        return self.evalFunctionBody(userDefinedFunc.body, &activationEnv);
    }

    fn evalFunctionBody(self: *Eva, blockStmt: Parser.BlockStatement, env: *Environment) Error!EvalResult {
        for (blockStmt.body) |stmt| {
            const result = try self.eval(stmt, env);
            if (result == .Return) {
                return if (result.Return) |value| value.* else EvalResult{ .Null = {} };
            }
        }

        return EvalResult{ .Null = {} };
    }

    fn evalUnaryExpression(self: *Eva, unaryExp: Parser.UnaryExpression, env: *Environment) Error!EvalResult {
        const operator = unaryExp.operator;
        const argument = try self.evalExpression(unaryExp.argument.*, env);

        switch (operator.type) {
            .LogicalNot => {
                if (argument != .Bool) {
                    return Error.InvalidOperandTypes;
                }

                return EvalResult{ .Bool = !argument.Bool };
            },
            .AdditiveOperator => {
                if (argument != .Number) {
                    return Error.InvalidOperandTypes;
                }

                return switch (operator.value[0]) {
                    '+' => argument,
                    '-' => EvalResult{ .Number = -argument.Number },
                    else => {
                        unreachable;
                    },
                };
            },
            else => {
                unreachable;
            },
        }
    }

    fn evalAssignmentExpression(self: *Eva, assignmentExp: Parser.AssignmentExpression, env: *Environment) Error!EvalResult {
        const left = assignmentExp.left.*;
        const right = assignmentExp.right.*;

        switch (assignmentExp.operator.type) {
            .SimpleAssign => {
                switch (left) {
                    .Identifier => |identifier| {
                        const value = try self.evalExpression(right, env);
                        try env.assign(identifier.name, value);
                        return value;
                    },
                    .MemberExpression => |memberExp| {
                        if (memberExp.computed) {
                            return Error.ComputedPropertyAccessNotSupported;
                        }
                        const object = try self.evalExpression(memberExp.object.*, env);
                        if (object != .Env) {
                            return Error.InvalidObject;
                        }
                        const property = memberExp.property.Identifier;
                        const value = try self.evalExpression(right, env);

                        try object.Env.define(property.name, value);
                        return value;
                    },
                    else => {
                        unreachable;
                    },
                }
            },
            else => {
                unreachable;
            },
        }
    }

    fn evalBinaryExpression(self: *Eva, binaryExp: Parser.BinaryExpression, env: *Environment) !EvalResult {
        const left = try self.evalExpression(binaryExp.left.*, env);
        const right = try self.evalExpression(binaryExp.right.*, env);
        const operator = binaryExp.operator;

        if (left != .Number or right != .Number) {
            return Error.InvalidOperandTypes;
        }

        switch (operator.type) {
            .AdditiveOperator, .MultiplicativeOperator => {
                return switch (operator.value[0]) {
                    '+' => EvalResult{ .Number = left.Number + right.Number },
                    '-' => EvalResult{ .Number = left.Number - right.Number },
                    '*' => EvalResult{ .Number = left.Number * right.Number },
                    '/' => EvalResult{ .Number = @divFloor(left.Number, right.Number) },
                    else => {
                        unreachable;
                    },
                };
            },
            .RelationalOperator => {
                if (std.mem.eql(u8, operator.value, ">=")) {
                    return EvalResult{ .Bool = left.Number >= right.Number };
                }

                if (std.mem.eql(u8, operator.value, "<=")) {
                    return EvalResult{ .Bool = left.Number <= right.Number };
                }

                return switch (operator.value[0]) {
                    '>' => EvalResult{ .Bool = left.Number > right.Number },
                    '<' => EvalResult{ .Bool = left.Number < right.Number },
                    else => {
                        unreachable;
                    },
                };
            },
            .EqualityOperator => {
                if (std.mem.eql(u8, operator.value, "==")) {
                    return EvalResult{ .Bool = left.Number == right.Number };
                }

                if (std.mem.eql(u8, operator.value, "!=")) {
                    return EvalResult{ .Bool = left.Number != right.Number };
                }

                unreachable;
            },
            else => {
                unreachable;
            },
        }
    }

    fn evalLiteral(_: *Eva, literal: Parser.Literal) !EvalResult {
        return switch (literal) {
            .NumericLiteral => |numericLiteral| EvalResult{ .Number = numericLiteral.value },
            .StringLiteral => |stringLiteral| EvalResult{ .String = stringLiteral.value },
            .BooleanLiteral => |boolLiteral| EvalResult{ .Bool = boolLiteral.value },
            else => {
                unreachable;
            },
        };
    }
};

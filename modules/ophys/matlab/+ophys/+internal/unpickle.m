function value = unpickle(bytes, path)
%unpickle The value a Python pickle (protocols 2 to 5) holds, read from its opcodes without Python, running nothing
%
%   suite2p's stat.npy is a NumPy array of dicts, pickled. Values read:
%   None is [], True and False logical, integers and floats double, text a
%   string, bytes uint8, lists, tuples and (from protocol 4) sets cell
%   rows, dicts structs (text keys made valid field names, other keys left
%   out), NumPy arrays their values in NumPy's shape (a 1-D array a column,
%   an array of objects a cell array; logical, integer and floating point
%   values; protocol 5's _frombuffer too), NumPy scalars their value, and
%   any other object [] (no class is looked up or run). Python's
%   ophys_adapters.read_pickled_npy unpickles with only NumPy's array, dtype
%   and scalar classes allowed, and reads the same values of what suite2p's
%   files hold. path is for messages.
    bytes = reshape(uint8(bytes), 1, []);
    n = numel(bytes);
    % Every value made is kept by number in kinds and values; the stack and the memo hold these numbers, so a list
    % or dict that is changed after it was put in the memo is changed wherever it is referenced, as in Python. (The
    % nested functions below share the variables of this one that they name, so their own have other names.)
    kinds = repmat({''}, 1, 256);
    values = cell(1, 256);
    count = 0;
    stack = zeros(1, 0);
    marks = zeros(1, 0);
    memo = zeros(1, 0);
    at = 1;
    while true
        if at > n
            fail('ends before its STOP')
        end
        op = double(bytes(at));
        at = at + 1;
        switch op
            case 128            % PROTO
                at = at + 1;
            case 149            % FRAME
                at = at + 8;
            case 46             % STOP
                value = materialize(pop());
                return
            case 40             % MARK
                marks(end + 1) = numel(stack); %#ok<AGROW>
            case 48             % POP
                pop();
            case 49             % POP_MARK
                popMark();
            case 50             % DUP
                push(stack(end));
            case 78             % NONE
                push(make('none', []));
            case 136            % NEWTRUE
                push(make('number', true));
            case 137            % NEWFALSE
                push(make('number', false));
            case 74             % BININT
                push(make('number', double(typecast(take(4), 'int32'))));
            case 75             % BININT1
                push(make('number', double(take(1))));
            case 77             % BININT2
                push(make('number', double(typecast(take(2), 'uint16'))));
            case 138            % LONG1
                push(make('number', signedOf(take(double(take(1))))));
            case 139            % LONG4
                push(make('number', signedOf(take(double(typecast(take(4), 'uint32'))))));
            case 71             % BINFLOAT: big-endian
                push(make('number', typecast(fliplr(take(8)), 'double')));
            case 88             % BINUNICODE
                push(make('text', textOf(take(double(typecast(take(4), 'uint32'))))));
            case 140            % SHORT_BINUNICODE
                push(make('text', textOf(take(double(take(1))))));
            case 141            % BINUNICODE8
                push(make('text', textOf(take(double(typecast(take(8), 'uint64'))))));
            case 84             % BINSTRING: Python 2 text, read as Latin-1
                push(make('text', char(take(double(typecast(take(4), 'int32'))))));
            case 85             % SHORT_BINSTRING
                push(make('text', char(take(double(take(1))))));
            case 66             % BINBYTES
                push(make('bytes', take(double(typecast(take(4), 'uint32')))));
            case 67             % SHORT_BINBYTES
                push(make('bytes', take(double(take(1)))));
            case {142, 150}     % BINBYTES8, BYTEARRAY8
                push(make('bytes', take(double(typecast(take(8), 'uint64')))));
            case {93, 143, 41}  % EMPTY_LIST, EMPTY_SET, EMPTY_TUPLE
                push(make('list', zeros(1, 0)));
            case 97             % APPEND
                entry = pop();
                values{stack(end)} = [values{stack(end)}, entry];
            case {101, 144}     % APPENDS, ADDITEMS
                entries = popMark();
                values{stack(end)} = [values{stack(end)}, entries];
            case {108, 116, 145}   % LIST, TUPLE, FROZENSET
                push(make('list', popMark()));
            case 133            % TUPLE1
                push(make('list', pop()));
            case 134            % TUPLE2
                entries = stack(end - 1:end);
                stack(end - 1:end) = [];
                push(make('list', entries));
            case 135            % TUPLE3
                entries = stack(end - 2:end);
                stack(end - 2:end) = [];
                push(make('list', entries));
            case 125            % EMPTY_DICT: keys over values
                push(make('dict', zeros(2, 0)));
            case 100            % DICT
                entries = popMark();
                push(make('dict', reshape(entries, 2, [])));
            case 115            % SETITEM
                entry = pop();
                entryKey = pop();
                values{stack(end)} = [values{stack(end)}, [entryKey; entry]];
            case 117            % SETITEMS
                entries = popMark();
                values{stack(end)} = [values{stack(end)}, reshape(entries, 2, [])];
            case 99             % GLOBAL: module and name, each ending in a newline
                moduleName = line();
                push(make('global', [moduleName, ' ', line()]));
            case 147            % STACK_GLOBAL
                globalName = values{pop()};
                push(make('global', [values{pop()}, ' ', globalName]));
            case {82, 129}      % REDUCE, NEWOBJ: a callable (or class) and its arguments
                args = pop();
                push(call(pop(), args));
            case 146            % NEWOBJ_EX
                pop();          % its keyword arguments
                args = pop();
                push(call(pop(), args));
            case 98             % BUILD: the object's state
                buildState = pop();
                if strcmp(kinds{stack(end)}, 'object')
                    values{stack(end)}.state = buildState;
                end
            case 112            % PUT
                remember(str2double(line()));
            case 113            % BINPUT
                remember(double(take(1)));
            case 114            % LONG_BINPUT
                remember(double(typecast(take(4), 'uint32')));
            case 148            % MEMOIZE
                remember(numel(memo));
            case 103            % GET
                recall(str2double(line()));
            case 104            % BINGET
                recall(double(take(1)));
            case 106            % LONG_BINGET
                recall(double(typecast(take(4), 'uint32')));
            otherwise
                fail(sprintf('has opcode %d, which this reader does not read', op))
        end
    end

    function fail(message)
        nansen.internal.throwError("invalid-data", "%s: its objects cannot be read (the pickle %s)", path, message)
    end

    function out = take(number_)
        % The next number_ bytes
        if at + number_ - 1 > n
            fail('is cut off')
        end
        out = bytes(at:at + number_ - 1);
        at = at + number_;
    end

    function text = line()
        % Text up to the next newline (GLOBAL, PUT and GET are opcodes of protocol 0, with text arguments)
        stop = find(bytes(at:end) == 10, 1);
        if isempty(stop)
            fail('is cut off')
        end
        text = char(bytes(at:at + stop - 2));
        at = at + stop;
    end

    function text = textOf(raw)
        % UTF-8 bytes as text: one character per code point, so protocol 2's bytes (_codecs.encode of Latin-1
        % text) are got back from the characters' codes
        if all(raw < 128)
            text = char(raw);
            return
        end
        raw = double(raw);
        points = zeros(1, 0);
        k = 1;
        while k <= numel(raw)
            if raw(k) >= 240
                width = 4;
                point = raw(k) - 240;
            elseif raw(k) >= 224
                width = 3;
                point = raw(k) - 224;
            elseif raw(k) >= 192
                width = 2;
                point = raw(k) - 192;
            else
                width = 1;
                point = raw(k);
            end
            if k + width - 1 > numel(raw)
                fail('has text that is not UTF-8')
            end
            for j = 1:width - 1
                point = point * 64 + raw(k + j) - 128;
            end
            points(end + 1) = point; %#ok<AGROW>
            k = k + width;
        end
        if any(points > 65535)   % outside the characters of one code unit: MATLAB's own decoding
            text = reshape(native2unicode(uint8(raw), 'UTF-8'), 1, []);
        else
            text = char(points);
        end
    end

    function number = signedOf(raw)
        % A little-endian signed integer of any number of bytes, as a double
        raw = double(raw);
        number = sum(raw .* 256 .^ (0:numel(raw) - 1));
        if ~isempty(raw) && raw(end) >= 128
            number = number - 256 ^ numel(raw);
        end
    end

    function index = make(kind, content)
        count = count + 1;
        if count > numel(kinds)
            kinds{2 * count} = '';
            values{2 * count} = [];
        end
        kinds{count} = kind;
        values{count} = content;
        index = count;
    end

    function push(index)
        stack(end + 1) = index;
    end

    function index = pop()
        if isempty(stack)
            fail('takes from an empty stack')
        end
        index = stack(end);
        stack(end) = [];
    end

    function items = popMark()
        % The items above the last mark, taken off with the mark
        if isempty(marks)
            fail('has no mark')
        end
        items = stack(marks(end) + 1:end);
        stack(marks(end) + 1:end) = [];
        marks(end) = [];
    end

    function remember(key)
        if isempty(stack) || isnan(key)
            fail('memoizes nothing')
        end
        memo(key + 1) = stack(end);
    end

    function recall(key)
        if isnan(key) || key + 1 > numel(memo) || memo(key + 1) == 0
            fail('gets what it did not memoize')
        end
        push(memo(key + 1));
    end

    function index = call(callable, arguments_)
        % What calling a global gives: _codecs.encode's bytes now (protocol 2 pickles bytes as Latin-1 text so), any
        % other an object of that name, with its arguments and (once BUILD gives it) its state, made a value at the end
        name = '';
        if strcmp(kinds{callable}, 'global')
            name = values{callable};
        end
        items = values{arguments_};
        if strcmp(name, '_codecs encode') && ~isempty(items) && strcmp(kinds{items(1)}, 'text')
            index = make('bytes', uint8(double(values{items(1)})));
            return
        end
        index = make('object', struct('name', name, 'arguments', arguments_, 'state', 0));
    end

    function out = materialize(index)
        % The MATLAB value of a value read
        switch kinds{index}
            case {'number', 'bytes'}
                out = values{index};
            case 'text'
                out = string(values{index});
            case 'list'
                items = values{index};
                out = cell(1, numel(items));
                for k = 1:numel(items)
                    out{k} = materialize(items(k));
                end
            case 'dict'
                pairs = values{index};
                out = struct();
                for k = 1:size(pairs, 2)
                    if strcmp(kinds{pairs(1, k)}, 'text')
                        out.(matlab.lang.makeValidName(values{pairs(1, k)})) = materialize(pairs(2, k));
                    end
                end
            case 'object'
                out = objectValue(values{index});
            otherwise   % None, or a global itself
                out = [];
        end
    end

    function out = objectValue(object)
        % NumPy's arrays, dtypes and scalars; [] for any other object
        out = [];
        arguments_ = values{object.arguments};
        switch object.name
            case {'numpy._core.multiarray _reconstruct', 'numpy.core.multiarray _reconstruct'}
                % the array's state: (version,) shape, dtype, Fortran order, and the values (bytes, or a list of objects)
                if object.state == 0 || ~strcmp(kinds{object.state}, 'list')
                    return
                end
                state = values{object.state};
                if numel(state) == 5
                    state = state(2:end);
                end
                if numel(state) == 4
                    out = arrayOf(state(4), state(2), materialize(state(1)), isequal(materialize(state(3)), true));
                end
            case {'numpy._core.numeric _frombuffer', 'numpy.core.numeric _frombuffer'}   % protocol 5: buffer, dtype, shape, order
                if numel(arguments_) == 4
                    out = arrayOf(arguments_(1), arguments_(2), materialize(arguments_(3)), ...
                        strcmp(kinds{arguments_(4)}, 'text') && strcmp(values{arguments_(4)}, 'F'));
                end
            case {'numpy._core.multiarray scalar', 'numpy.core.multiarray scalar'}   % its dtype and bytes
                if numel(arguments_) == 2
                    out = arrayOf(arguments_(2), arguments_(1), {}, false);
                end
            case 'numpy dtype'   % its type code, and from its state the byte order
                out = struct('code', '', 'order', '<');
                if ~isempty(arguments_) && strcmp(kinds{arguments_(1)}, 'text')
                    out.code = values{arguments_(1)};
                end
                if object.state ~= 0 && strcmp(kinds{object.state}, 'list')
                    state = values{object.state};
                    if numel(state) >= 2 && strcmp(kinds{state(2)}, 'text')
                        out.order = values{state(2)};
                    end
                end
        end
    end

    function out = arrayOf(data, dtype, shape, fortran)
        % A NumPy array of the dtype (a value read) and shape (a cell of numbers; {} for a scalar) from its data
        out = [];
        if ~strcmp(kinds{dtype}, 'object') || ~iscell(shape)
            return
        end
        type = objectValue(values{dtype});
        if ~isstruct(type)
            return
        end
        shape = cellfun(@double, shape);
        code = regexprep(type.code, '^[<>=|]', '');
        if startsWith(code, 'O')   % objects: the data is a list of them
            if ~strcmp(kinds{data}, 'list')
                return
            end
            items = values{data};
            elements = cell(numel(items), 1);
            for k = 1:numel(items)
                elements{k} = materialize(items(k));
            end
        else
            classes = struct('b1', 'logical', 'u1', 'uint8', 'i1', 'int8', 'u2', 'uint16', 'i2', 'int16', ...
                'u4', 'uint32', 'i4', 'int32', 'u8', 'uint64', 'i8', 'int64', 'f4', 'single', 'f8', 'double');
            widths = struct('b1', 1, 'u1', 1, 'i1', 1, 'u2', 2, 'i2', 2, 'u4', 4, 'i4', 4, 'u8', 8, 'i8', 8, 'f4', 4, 'f8', 8);
            if ~isfield(classes, code) || ~strcmp(kinds{data}, 'bytes')
                return   % other types (text, complex, records) are not read
            end
            raw = reshape(values{data}, 1, []);
            if mod(numel(raw), widths.(code)) ~= 0
                return
            end
            if strcmp(code, 'b1')
                elements = raw(:) ~= 0;
            else
                elements = typecast(raw, classes.(code));
                if strcmp(type.order, '>')
                    elements = swapbytes(elements);
                end
                elements = elements(:);
            end
        end
        if numel(shape) <= 1   % a scalar, or a 1-D array as a column
            out = elements;
        elseif numel(elements) == prod(shape) && fortran
            out = reshape(elements, shape);
        elseif numel(elements) == prod(shape)
            out = permute(reshape(elements, fliplr(shape)), numel(shape):-1:1);
        end
    end
end

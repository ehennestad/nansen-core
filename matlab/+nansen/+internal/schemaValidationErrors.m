function errors = schemaValidationErrors(instance, schema)
%schemaValidationErrors Validate a decoded JSON instance against a decoded draft-07 schema
%
%   errors = schemaValidationErrors(instance, schema) returns a string array
%   of "[path] message" entries, empty when the instance is valid.
%
%   This interprets the keyword subset the NANSEN schemas use, so the reader
%   validates against the schema files themselves instead of hand-written
%   checks that would drift. An unknown keyword raises rather than being
%   ignored. Because jsondecode is lossy, a one-element array of objects is
%   indistinguishable from an object and [] from null; both readings are
%   accepted where the schema allows either.
%
%   Ported from the Dataset Structure Model's MATLAB reader
%   (dsm.internal.schemaValidationErrors). Keep the keyword list in step with
%   MATLAB_KEYWORDS in python/tests/test_schemas.py.

    arguments
        instance
        schema (1,1) struct
    end
    errors = validateNode(instance, schema, schema, "$", string.empty(1, 0));
end

function errors = validateNode(value, schema, root, path, errors)
    kw = keywordFields();

    if isfield(schema, kw.Ref)
        % draft-07: siblings of $ref are ignored
        errors = validateNode(value, resolveRef(root, schema.(kw.Ref)), root, path, errors);
        return
    end
    assertKnownKeywords(schema, kw)

    if isfield(schema, "type") && ~typeMatches(value, schema.type)
        errors(end+1) = sprintf("[%s] is not of type %s", path, strjoin(cellstr(string(schema.type)), " | "));
        return
    end
    if isfield(schema, "const") && ~valuesEqual(value, schema.const)
        errors(end+1) = sprintf("[%s] must equal %s", path, string(schema.const));
    end
    if isfield(schema, "enum") && ~inEnum(value, schema.enum)
        errors(end+1) = sprintf("[%s] %s is not one of the allowed values", path, describe(value));
    end
    if isfield(schema, "pattern") && isText(value) && isempty(regexp(char(value), schema.pattern, "once"))
        errors(end+1) = sprintf("[%s] '%s' does not match pattern %s", path, char(value), schema.pattern);
    end

    if isObjectLike(value)
        names = fieldnames(value);
        for required = nansen.internal.asCellstr(nansen.internal.getField(schema, "required", {}))
            if ~ismember(required{1}, names)
                errors(end+1) = sprintf("[%s] '%s' is a required property", path, required{1}); %#ok<AGROW>
            end
        end
        properties = nansen.internal.getField(schema, "properties", struct());
        propertyNames = fieldnames(properties);
        for i = 1:numel(names)
            name = names{i};
            childPath = path + "." + name;
            if ismember(name, propertyNames)
                errors = validateNode(value.(name), properties.(name), root, childPath, errors);
            elseif isfield(schema, "additionalProperties")
                extra = schema.additionalProperties;
                if islogical(extra) && ~extra
                    errors(end+1) = sprintf("[%s] additional property '%s' is not allowed", path, name); %#ok<AGROW>
                elseif isstruct(extra)
                    errors = validateNode(value.(name), extra, root, childPath, errors);
                end
            end
            if isfield(schema, "propertyNames")
                errors = validateNode(name, schema.propertyNames, root, path + ".(" + name + ")", errors);
            end
        end
        if isfield(schema, "minProperties") && numel(names) < schema.minProperties
            errors(end+1) = sprintf("[%s] has fewer than %d properties", path, schema.minProperties);
        end
    end

    if isArrayLike(value)
        items = arrayItems(value);
        if isfield(schema, "minItems") && numel(items) < schema.minItems
            errors(end+1) = sprintf("[%s] has fewer than %d items", path, schema.minItems);
        end
        if isfield(schema, "uniqueItems") && schema.uniqueItems && ~allUnique(items)
            errors(end+1) = sprintf("[%s] has duplicate items", path);
        end
        if isfield(schema, "items") && isstruct(schema.items) && ~isempty(fieldnames(schema.items))
            for i = 1:numel(items)
                errors = validateNode(items{i}, schema.items, root, sprintf("%s[%d]", path, i - 1), errors);
            end
        end
    end

    for sub = nansen.internal.asCellOfStructs(nansen.internal.getField(schema, "allOf", {}))
        errors = validateNode(value, sub{1}, root, path, errors);
    end
    if isfield(schema, "anyOf")
        passes = cellfun(@(sub) isempty(validateNode(value, sub, root, path, string.empty(1, 0))), ...
            nansen.internal.asCellOfStructs(schema.anyOf));
        if ~any(passes)
            errors(end+1) = sprintf("[%s] does not satisfy any of the anyOf alternatives", path);
        end
    end
    if isfield(schema, "oneOf")
        passes = cellfun(@(sub) isempty(validateNode(value, sub, root, path, string.empty(1, 0))), ...
            nansen.internal.asCellOfStructs(schema.oneOf));
        if sum(passes) ~= 1
            errors(end+1) = sprintf("[%s] must satisfy exactly one oneOf alternative, satisfies %d", path, sum(passes));
        end
    end
    if isfield(schema, kw.Not) && isempty(validateNode(value, schema.(kw.Not), root, path, string.empty(1, 0)))
        errors(end+1) = sprintf("[%s] must not be valid against the 'not' schema", path);
    end
    if isfield(schema, kw.If)
        condition = isempty(validateNode(value, schema.(kw.If), root, path, string.empty(1, 0)));
        if condition && isfield(schema, "then")
            errors = validateNode(value, schema.then, root, path, errors);
        elseif ~condition && isfield(schema, kw.Else)
            errors = validateNode(value, schema.(kw.Else), root, path, errors);
        end
    end
end

function kw = keywordFields()
%keywordFields Field names jsondecode gives schema keywords that need special handling
    % Ask jsondecode itself: it keeps keyword names ("if", "else", "not")
    % verbatim as field names and rewrites only invalid characters
    % ("$ref" -> "x_ref"), which differs from matlab.lang.makeValidName.
    % The struct fields are capitalised because "if", "else" and "not" are
    % MATLAB keywords.
    decoded = fieldnames(jsondecode('{"$ref":0,"$schema":0,"$id":0,"if":0,"else":0,"not":0}'));
    kw = struct("Ref", decoded{1}, "Schema", decoded{2}, "Id", decoded{3}, ...
        "If", decoded{4}, "Else", decoded{5}, "Not", decoded{6});
end

function assertKnownKeywords(schema, kw)
    known = ["type", "required", "properties", "additionalProperties", "propertyNames", "minProperties", ...
        "items", "minItems", "uniqueItems", "enum", "const", "pattern", "default", "examples", ...
        "allOf", "anyOf", "oneOf", "then", "definitions", "title", "description", ...
        kw.Ref, kw.Schema, kw.Id, kw.If, kw.Else, kw.Not];
    unknown = setdiff(string(fieldnames(schema)), known);
    if ~isempty(unknown)
        error("nansen:schema:UnsupportedKeyword", ...
            "The MATLAB validator does not implement schema keyword(s): %s", strjoin(unknown, ", "))
    end
end

function target = resolveRef(root, ref)
    prefix = "#/definitions/";
    if ~startsWith(ref, prefix)
        error("nansen:schema:UnsupportedRef", "Only local #/definitions references are supported, got %s", ref)
    end
    target = root.definitions.(extractAfter(ref, prefix));
end

function tf = typeMatches(value, type)
    tf = false;
    % jsondecode returns a column cell for a type list; a for loop iterates columns
    for candidate = reshape(cellstr(string(type)), 1, [])
        switch candidate{1}
            case "string"
                tf = isText(value);
            case "boolean"
                tf = islogical(value) && isscalar(value);
            case "integer"
                tf = isnumeric(value) && isscalar(value) && mod(value, 1) == 0;
            case "number"
                tf = isnumeric(value) && isscalar(value);
            case "null"
                tf = isnumeric(value) && isempty(value);
            case "object"
                tf = isObjectLike(value);
            case "array"
                tf = isArrayLike(value);
            otherwise
                error("nansen:schema:UnsupportedType", "Unsupported schema type %s", candidate{1})
        end
        if tf
            return
        end
    end
end

function tf = isText(value)
    tf = ischar(value) || (isstring(value) && isscalar(value));
end

function tf = isObjectLike(value)
    tf = isstruct(value) && isscalar(value);
end

function tf = isArrayLike(value)
    % A scalar struct may be a one-element object array; [] may be an empty array.
    tf = iscell(value) || isstruct(value) || ...
        ((isnumeric(value) || islogical(value)) && (isempty(value) || numel(value) > 1));
end

function items = arrayItems(value)
    if iscell(value)
        items = reshape(value, 1, []);
    elseif isstruct(value)
        items = num2cell(reshape(value, 1, []));
    else
        items = num2cell(reshape(value, 1, []));
    end
end

function tf = allUnique(items)
    if all(cellfun(@isText, items))
        tf = numel(unique(cellfun(@char, items, "UniformOutput", false))) == numel(items);
        return
    end
    tf = true;
    for i = 1:numel(items)
        for j = i+1:numel(items)
            if valuesEqual(items{i}, items{j})
                tf = false;
                return
            end
        end
    end
end

function tf = inEnum(value, allowed)
    if iscell(allowed)
        tf = any(cellfun(@(a) valuesEqual(value, a), allowed));
    elseif isnumeric(allowed) || islogical(allowed)
        tf = (isnumeric(value) || islogical(value)) && isscalar(value) && any(allowed == value);
    else
        tf = valuesEqual(value, allowed);
    end
end

function tf = valuesEqual(a, b)
    if isText(a) && isText(b)
        tf = strcmp(char(a), char(b));
    elseif isText(a) || isText(b)
        tf = false;
    else
        tf = isequal(a, b);
    end
end

function text = describe(value)
    if isText(value)
        text = "'" + string(value) + "'";
    elseif isnumeric(value) || islogical(value)
        text = string(mat2str(value));
    else
        text = string(class(value));
    end
end

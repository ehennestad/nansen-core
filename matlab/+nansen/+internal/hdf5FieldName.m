function name = hdf5FieldName(name, taken)
%hdf5FieldName A struct field for the name of an HDF5 member or attribute, as Python's nansen.hdf5.field_name
%
%   name = nansen.internal.hdf5FieldName(name, taken): characters other
%   than ASCII letters, digits and _ as _, x before a name that does not
%   start with a letter, at most 63 characters (namelengthmax), and _2,
%   _3, ... after one already taken (a string array of the fields so far).
    arguments
        name (1,1) string
        taken string = strings(1, 0)
    end
    name = regexprep(name, "[^A-Za-z0-9_]", "_");
    if isempty(regexp(name, "^[A-Za-z]", "once"))
        name = "x" + name;
    end
    name = extractBefore(name, min(strlength(name), 63) + 1);
    base = name;
    number = 2;
    while any(taken == name)
        suffix = "_" + string(number);
        name = extractBefore(base, min(strlength(base), 63 - strlength(suffix)) + 1) + suffix;
        number = number + 1;
    end
end

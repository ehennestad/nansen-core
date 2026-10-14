classdef NansenError < MException
%NansenError An error carrying a code from docs/conventions.md#error-codes
%
%   The Code ("file-not-found", "duplicate-key", ...) is the same in the
%   MATLAB and Python implementations. The identifier is
%   "nansen:<CodeInCamelCase>", e.g. "nansen:DuplicateKey".

    properties (SetAccess = immutable)
        Code (1,1) string
    end

    methods
        function obj = NansenError(code, message)
            arguments
                code (1,1) string
                message (1,1) string
            end
            words = split(code, "-");
            identifier = "nansen:" + join(upper(extractBefore(words, 2)) + extractAfter(words, 1), "");
            obj@MException(char(identifier), '%s', char("[" + code + "] " + message));
            obj.Code = code;
        end
    end
end

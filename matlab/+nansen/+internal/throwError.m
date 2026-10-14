function throwError(code, message, varargin)
%throwError Throw a nansen.NansenError with a code from docs/conventions.md
%
%   nansen.internal.throwError(code, format, args...) formats the message
%   with sprintf.
    if ~isempty(varargin)
        message = sprintf(message, varargin{:});
    end
    throwAsCaller(nansen.NansenError(code, message))
end

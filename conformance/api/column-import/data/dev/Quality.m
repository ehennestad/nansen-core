classdef Quality < nansen.metadata.abstract.TableVariable
%QUALITY Definition for table variable
%   A table variable whose values are picked from a list, as dev's TemplateListVariable makes one.
%
%   See also nansen.metadata.abstract.TableVariable

    properties (Constant)
        IS_EDITABLE = true
        DEFAULT_VALUE = {'N/A'}
        LIST_ALTERNATIVES = {'good', 'fair', "poor"}
    end

    methods
        function obj = Quality(varargin)
            obj@nansen.metadata.abstract.TableVariable(varargin{:});
        end
    end
end

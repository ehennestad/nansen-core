classdef Reviewed < nansen.metadata.abstract.TableVariable
%REVIEWED Definition for table variable
%
%   See also nansen.metadata.abstract.TableVariable

    properties (Constant)
        IS_EDITABLE = true
        DEFAULT_VALUE = false
    end

    methods
        function obj = Reviewed(varargin)
            obj@nansen.metadata.abstract.TableVariable(varargin{:});
        end
    end
end

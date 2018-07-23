import std.stdio;
import std.range;
import std.range.primitives;
import std.traits;
import std.algorithm.searching;


// Greedy lazy range: consume not more char than requested,
// while eating as much line split as possible
// Cannot take an InputRange as input due to look-ahead parsing
auto spliceLines(Range)(Range input)
    if(isForwardRange!Range && isSomeChar!(ElementEncodingType!Range) && !isConvertibleToString!Range)
{
    struct Result
    {
        private Range _input;

        this(Range input)
        {
            _input = input;
            trim();
        }

        private void trim()
        {
            while(_input.startsWith('\\') && _input.save.dropOne.startsWith('\n'))
                _input.popFrontExactly(2);
        }

        @property bool empty()
        {
            return _input.empty;
        }

        @property auto front()
        {
            return _input.front;
        }

        void popFront()
        {
            _input.popFront();
            trim();
        }

        @property auto save()
        {
            return Result(_input.save);
        }

        @property auto filename() { return _input.filename; }
        @property auto line() { return _input.line; }
        @property auto col() { return _input.col; }
        @property auto pos() { return _input.pos; }
    }

    return Result(input);
}



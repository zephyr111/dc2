import std.stdio;
import std.range;
import std.range.primitives;
import std.traits;
import std.algorithm.comparison;
import std.algorithm.searching;
import std.string;
import utils;


// Lazy range: consume not more char than requested
// Cannot take an InputRange as input due to look-ahead parsing
auto substituteTrigraph(Range)(Range input)
    if(isForwardRange!Range && isSomeChar!(ElementEncodingType!Range) && !isConvertibleToString!Range)
{
    static struct Result
    {
        alias This = typeof(this);

        private Range _input;

        this(Range input)
        {
            _input = input;
        }

        @property bool empty()
        {
            return _input.empty;
        }

        @property auto front()
        {
            auto first = _input.front;

            if(first == '?')
            {
                auto lookAhead = _input.save.dropOne;

                if(lookAhead.skipIf('?') && !lookAhead.empty)
                {
                    const long pos = "=/'()!<>-".indexOf(lookAhead.front);

                    if(pos >= 0)
                        return "#\\^[]|{}~"[pos];
                }
            }

            return first;
        }

        void popFront()
        {
            auto first = _input.front;
            _input.popFront();

            if(first == '?' && _input.startsWith('?'))
            {
                auto lookAhead = _input.save.dropOne;

                if(!lookAhead.empty && "=/'()!<>-".canFind(lookAhead.front))
                    _input = lookAhead.dropOne;
            }
        }

        @property auto save()
        {
            return This(_input.save);
        }

        @property auto filename() const { return _input.filename; }
        @property auto line() const { return _input.line; }
        @property auto col() const { return _input.col; }
        @property auto pos() const { return _input.pos; }
    }

    return Result(input);
}



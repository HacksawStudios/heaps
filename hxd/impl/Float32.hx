package hxd.impl;

typedef Float32 = #if hl hl.F32 #elseif js __Float32 #else Float #end;

abstract __Float32(Float) from Float to Float {
	private static inline final MAX_SAFE_FLOAT = 3.402823466e+38;
	private static inline final CLAMP_MIN = -MAX_SAFE_FLOAT;
	private static inline final CLAMP_MAX = MAX_SAFE_FLOAT;

	private inline function new(v:Float) {
		this = saturate(v);
	}

	private static inline function make(v:Float):__Float32 {
		return new __Float32(v);
	}

	private static inline function saturate(v:Float):__Float32 {
		return Math.min(Math.max(v, CLAMP_MIN), CLAMP_MAX);
	}

	@:op(-A) private inline function negate():__Float32 {
		return saturate(this * -1);
	}

	@:op(++A) private inline function preIncrement():__Float32 {
		return this = saturate(++this);
	}

	@:op(A++) private inline function postIncrement():__Float32 {
		var ret = this++;
		this = saturate(this);
		return ret;
	}

	@:op(--A) private inline function preDecrement():__Float32 {
		return this = saturate(--this);
	}

	@:op(A--) private inline function postDecrement():__Float32 {
		var ret = this--;
		this = saturate(this);
		return ret;
	}

	@:op(A * B) private static inline function mul(a:__Float32, b:__Float32):__Float32 {
		return saturate((a : Float) * (b : Float));
	}

	@:op(A / B) private static inline function div(a:__Float32, b:__Float32):__Float32{
		return saturate((a : Float) / (b : Float));
	}

	@:op(A + B) private static inline function add(a:__Float32, b:__Float32):__Float32 {
		return saturate((a : Float) + (b : Float));
	}

	@:op(A - B) private static inline function sub(a:__Float32, b:__Float32):__Float32{
		return saturate((a : Float) - (b : Float));
	}

	@:op(A == B) private static function eq(a:__Float32, b:__Float32):Bool{
		return (a : Float) == (b : Float);
	}

	@:op(A != B) private static function neq(a:__Float32, b:__Float32):Bool{
		return (a : Float) != (b : Float);
	}

	@:op(A < B) private static function lt(a:__Float32, b:__Float32):Bool{
		return (a : Float) < (b : Float);
	}

	@:op(A <= B) private static function lte(a:__Float32, b:__Float32):Bool{
		return (a : Float) <= (b : Float);
	}  	

	@:op(A > B) private static function gt(a:__Float32, b:__Float32):Bool{
		return (a : Float) > (b : Float);
	}

	@:op(A >= B) private static function gte(a:__Float32, b:__Float32):Bool{
		return (a : Float) >= (b : Float);
	}
}

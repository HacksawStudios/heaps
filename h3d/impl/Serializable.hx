package h3d.impl;

#if !hxbit
private interface EmptyInterface {}
#end

typedef Serializable = #if hxbit hxbit.Serializable #else EmptyInterface #end;

#if hxbit
class SceneSerializer extends hxbit.Serializer {

	public var materialRef = new Map<String,h3d.mat.Material>();

	var version = 0;

	var resPath : String = MacroHelper.getResourcesPath();
	var shaderVarIndex : Int;
	var shaderUID = 0;
	var shaderIndexes = new Map<hxsl.Shader,Int>();
	var cachedShaders = new Array<hxsl.Shader>();
	var cachedTextures = new Map<Int,h3d.mat.Texture>();

	function addTexture( t : h3d.mat.Texture ) {
		if( t == null ) {
			addInt(0);
			return true;
		}
		addInt(t.id);
		if( cachedTextures.exists(t.id) )
			return true;
		addInt(t.filter.getIndex());
		addInt(t.mipMap.getIndex());
		addInt(t.wrap.getIndex());
		cachedTextures.set(t.id, t);
		if( t.name != null && hxd.res.Loader.currentInstance.exists(t.name) ) {
			addInt(1);
			addString(t.name);
			return true;
		}
		if( t.flags.has(Serialize) ) {
			addInt(2);
			var pix = t.capturePixels();
			addInt(t.width);
			addInt(t.height);
			addInt(t.flags.toInt());
			addInt(t.format.getIndex());
			addInt(pix.format.getIndex());
			addBytesSub(pix.bytes, 0, t.width * t.height * hxd.Pixels.bytesPerPixel(pix.format));
			return true;
		}
		var tch = Std.instance(t, h3d.mat.TextureChannels);
		if( tch != null ) {
			addInt(3);
			var channels = @:privateAccess tch.channels;
			addInt(t.width);
			addInt(t.height);
			addInt(t.flags.toInt());
			addInt(t.format.getIndex());
			for( i in 0...4 ) {
				var c = channels[i];
				if( c == null ) {
					addString(null);
					continue;
				}
				if( c.r == null )
					return false;
				addString(c.r.entry.path);
				addInt(c.c.toInt());
			}
			return true;
		}
		return false;
	}

	function getTexture() {
		var tid = getInt();
		if( tid == 0 )
			return null;
		var t = cachedTextures.get(tid);
		if( t != null )
			return t;
		var filter = h3d.mat.Data.Filter.createByIndex(getInt());
		var mipmap = h3d.mat.Data.MipMap.createByIndex(getInt());
		var wrap = h3d.mat.Data.Wrap.createByIndex(getInt());
		var kind = getInt();
		switch( kind ) {
		case 1:
			t = resolveTexture(getString());
		case 2,3:
			var width = getInt(), height = getInt();
			var flags : haxe.EnumFlags<h3d.mat.Data.TextureFlags> = haxe.EnumFlags.ofInt(getInt());
			var format = h3d.mat.Data.TextureFormat.createByIndex(getInt());
			var flags = [for( f in h3d.mat.Data.TextureFlags.createAll() ) if( flags.has(f) ) f];
			if( kind == 2 ) {
				var pixFormat = h3d.mat.Data.TextureFormat.createByIndex(getInt());
				t = new h3d.mat.Texture(width, height, flags, format);
				t.uploadPixels(new hxd.Pixels(width, height, getBytes(), pixFormat));
			} else {
				var ct = new h3d.mat.TextureChannels(width, height, flags, format);
				ct.allowAsync = false;
				for( i in 0...4 ) {
					var resPath = getString();
					if( resPath == null ) continue;
					var c = hxd.Pixels.Channel.fromInt(getInt());
					ct.setResource(hxd.Pixels.Channel.fromInt(i), hxd.res.Loader.currentInstance.load(resPath).toImage(), c);
				}
				t = ct;
			}
		default:
			throw "assert";
		}
		t.filter = filter;
		t.mipMap = mipmap;
		t.wrap = wrap;
		cachedTextures.set(tid, t);
		return t;
	}

	function resolveTexture( path : String ) {
		return hxd.res.Loader.currentInstance.load(path).toTexture();
	}

	public function loadHMD( path : String ) {
		return hxd.res.Loader.currentInstance.load(path).toHmd();
	}

	public function addShader( s : hxsl.Shader ) {
		if( s == null ) {
			addInt(0);
			return;
		}
		var id = shaderIndexes.get(s);
		if( id != null ) {
			addInt(id);
			return;
		}
		id = ++shaderUID;
		shaderIndexes.set(s, id);
		addInt(id);
		addString(Type.getClassName(Type.getClass(s)));
		shaderVarIndex = 0;
		for( v in @:privateAccess s.shader.data.vars )
			addShaderVar(v, s);
	}

	function loadShader( name : String ) : hxsl.Shader {
		return null;
	}

	public function getShader() {
		var id = getInt();
		if( id == 0 )
			return null;
		var s = cachedShaders[id];
		if( s != null )
			return s;
		var sname = getString();
		var cl : Class<hxsl.Shader> = cast Type.resolveClass(sname);
		if( cl == null ) {
			s = loadShader(sname);
			if( s == null )
				throw "Missing shader " + sname;
		} else
			s = Type.createEmptyInstance(cl);
		@:privateAccess s.initialize();
		for( v in @:privateAccess s.shader.data.vars ) {
			if( !canSerializeVar(v) ) continue;
			var val : Dynamic = getShaderVar(v, s);
			Reflect.setField(s, v.name+"__", val);
		}
		cachedShaders[id] = s;
		return s;
	}

	function canSerializeVar( v : hxsl.Ast.TVar ) {
		return v.kind == Param && (v.qualifiers == null || v.qualifiers.indexOf(Ignore) < 0);
	}

	function addShaderVar( v : hxsl.Ast.TVar, s : hxsl.Shader ) {
		if( v.kind != Param )
			return;
		switch( v.type ) {
		case TStruct(vl):
			for( v in vl )
				addShaderVar(v, s);
			return;
		default:
		}
		if( !canSerializeVar(v) ) {
			shaderVarIndex++;
			return;
		}
		var val : Dynamic = s.getParamValue(shaderVarIndex++);
		switch( v.type ) {
		case TBool:
			addBool(val);
		case TInt:
			addInt(val);
		case TFloat:
			addFloat(val);
		case TVec(n, VFloat):
			var v : h3d.Vector = val;
			addFloat(v.x);
			addFloat(v.y);
			if( n >= 3 ) addFloat(v.z);
			if( n >= 4 ) addFloat(v.w);
		case TSampler2D:
			if( !addTexture(val) )
				throw "Cannot serialize unnamed texture " + s+"."+v.name+" = "+val;
		default:
			throw "Cannot serialize macro var " + v.name+":"+hxsl.Ast.Tools.toString(v.type)+" in "+s;
		}
	}

	function getShaderVar( v : hxsl.Ast.TVar, s : hxsl.Shader ) : Dynamic {
		switch( v.type ) {
		case TStruct(vl):
			var obj = {};
			for( v in vl ) {
				if( !canSerializeVar(v) ) continue;
				Reflect.setField(obj, v.name, getShaderVar(v, s));
			}
			return obj;
		default:
		}
		switch( v.type ) {
		case TBool:
			return getBool();
		case TFloat:
			return getFloat();
		case TInt:
			return getInt();
		case TVec(n, VFloat):
			var v = new h3d.Vector(getFloat(), getFloat());
			if( n >= 3 ) v.z = getFloat();
			if( n >= 4 ) v.w = getFloat();
			return v;
		case TSampler2D:
			return getTexture();
		default:
			throw "Cannot unserialize macro var " + v.name+":"+hxsl.Ast.Tools.toString(v.type);
		}
	}

	function initSCNPaths( resPath : String, projectPath : String ) {
		this.resPath = resPath;
	}

	public function loadSCN( bytes ) {
		setInput(bytes, 0);
		if( getString() != "SCN" )
			throw "Invalid SCN file";
		version = getInt();
		beginLoad(bytes, inPos);
		initSCNPaths(getString(), getString());
		var objs = [];
		for( i in 0...getInt() ) {
			var obj : h3d.scene.Object = cast getAnyRef();
			objs.push(obj);
		}
		endLoad();
		return { content : objs };
	}

	public function saveSCN( obj : h3d.scene.Object, includeRoot : Bool ) {
		begin();
		addString("SCN");
		addInt(version); // version

		var pos = out.length;
		usedClasses = [];
		addString(resPath);
		#if sys
		addString(Sys.getCwd());
		#else
		addString(null);
		#end

		var objs = includeRoot ? [obj] : [for( o in obj ) o];
		objs = [for( o in obj ) if( @:privateAccess !o.flags.has(FNoSerialize) ) o];
		addInt(objs.length);
		for( o in objs )
			addAnyRef(o);

		return endSave(pos);
	}

}
#end

package hxd.res;
#if js
import h3d.impl.GlDriver;
import h3d.mat.Texture;
import js.html.ImageData;
using thx.Arrays;
class BasisTextureLoader {
	public static var workerLimit = 4;
	public static var transcoderPath = 'vendor/basis_transcoder.js';
	public static var wasmPath = 'vendor/basis_transcoder.wasm';

	static var _workerNextTaskID = 1;
	static var _workerSourceURL:String;
	static var _workerConfig = {
		format: 0,
		astcSupported: false,
		etc1Supported: false,
		etc2Supported: false,
		dxtSupported: false,
		pvrtcSupported: false,
	};
	static var _workerPool:Array<Ktx2.WorkerTask> = [];
	static var _transcoderPending:js.lib.Promise<Dynamic>;
	static var _transcoderBinary:Dynamic;

	public static function getTexture(bytes:haxe.io.BytesData) {
		_workerConfig = detectSupport();
		return createTexture(bytes);
	}

	static function detectSupport() {
		final driver:h3d.impl.GlDriver = cast h3d.Engine.getCurrent().driver;
		final transcoderFormat = driver.textureSupport;
		//driver.gl.getExtension('WEBGL_compressed_texture_s3tc');
		trace('transcoderFormat: ${transcoderFormat}');
		return switch transcoderFormat {
			case ETC(v):
				final etc2 = v == 1; 
				trace('etc2: ${etc2}');
				{
					format: Ktx2.TranscoderFormat.ETC1,
					astcSupported: false,
					etc1Supported: !etc2,
					etc2Supported: etc2,
					dxtSupported: false,
					pvrtcSupported: false,
				}
			case ASTC(_): {
				format:Ktx2.TranscoderFormat.ASTC_4x4,
				astcSupported: true,
				etc1Supported: false,
				etc2Supported: false,
				dxtSupported: false,
				pvrtcSupported: false,
			}
			case S3TC(_): 
				trace('************* S3TC');
			{
				format:Ktx2.TranscoderFormat.BC3,
				astcSupported: false,
				etc1Supported: false,
				etc2Supported: false,
				dxtSupported: true,
				pvrtcSupported: false,
			}
			case PVRTC(_): {
				format:Ktx2.TranscoderFormat.PVRTC1_4_RGBA,
				astcSupported: false,
				etc1Supported: false,
				etc2Supported: false,
				dxtSupported: false,
				pvrtcSupported: true,
			}
			default: throw 'No suitable compressed texture format found.';
		}
	}

	static function createTexture(buffer:haxe.io.BytesData):js.lib.Promise<h3d.mat.Texture> {
		var worker:js.html.Worker;
		var workerTask:Ktx2.WorkerTask;
		var taskID:Int;
		var texturePending = getWorker().then((task) -> {
			workerTask = task;
			worker = workerTask.worker;
			taskID = _workerNextTaskID++;
			return new js.lib.Promise((resolve, reject) -> {
				workerTask.callbacks.set(taskID, {
					resolve: resolve,
					reject: reject,
				});
				workerTask.taskCosts.set(taskID, buffer.byteLength);
				workerTask.taskLoad += workerTask.taskCosts.get(taskID);
				worker.postMessage({type: 'transcode', id: taskID, buffer: buffer}, [buffer]);
			});
		}).then((message:Ktx2.BasisWorkerMessage) -> {
				final w = message.data.width;
				final h = message.data.height;
				final create = fmt -> {
					final face = message.data.faces[0];
					final mipmaps:Array<js.html.ImageData> = face.mipmaps;
					final texture = new h3d.mat.Texture(w, h, null, fmt);
					var level = 0;
					for (mipmap in mipmaps) {
						final bytes = haxe.io.Bytes.ofData(cast mipmap.data);
						final pixels = new hxd.Pixels(mipmap.width, mipmap.height, bytes, fmt);
						texture.uploadPixels(pixels, level);
						level++;
					}
					if(mipmaps.length>1) {
						texture.flags.set(MipMapped);
						texture.mipMap = Linear;
					}
					texture;
				}

				final texture = switch message.data.format {
					case Ktx2.EngineFormat.RGBA_ASTC_4x4_Format:
						create(hxd.PixelFormat.ASTC(10));
					case Ktx2.EngineFormat.RGB_BPTC_UNSIGNED_Format, Ktx2.EngineFormat.RGBA_BPTC_Format:
						create(hxd.PixelFormat.S3TC(1));
					case Ktx2.EngineFormat.RGBA_S3TC_DXT5_Format:
						create(hxd.PixelFormat.S3TC(3));
					case Ktx2.EngineFormat.RGB_ETC1_Format:
						create(hxd.PixelFormat.ETC(0));
					case Ktx2.EngineFormat.RGB_PVRTC_4BPPV1_Format, Ktx2.EngineFormat.RGBA_PVRTC_4BPPV1_Format:
						create(hxd.PixelFormat.PVRTC(9));
					default:
						throw 'BasisTextureLoader: No supported format available. Format according to transcoder: ${message.data.format}';
				}

				return texture;
			}).then((tex) -> {
				if (workerTask != null && taskID > 0) {
					workerTask.taskLoad -= workerTask.taskCosts.get(taskID);
					workerTask.callbacks.remove(taskID);
					workerTask.taskCosts.remove(taskID);
				}
				return tex;
			});
		return texturePending;
	}

	static function initTranscoder() {
		if (_transcoderBinary == null) {
			// Load transcoder wrapper.
			final jsLoader = new hxd.net.BinaryLoader(transcoderPath);
			final jsContent = new js.lib.Promise((resolve, reject) -> {
				jsLoader.onLoaded = resolve;
				jsLoader.onError = reject;
				jsLoader.load();
			});
			// Load transcoder WASM binary.
			final binaryLoader = new hxd.net.BinaryLoader(wasmPath);
			final binaryContent = new js.lib.Promise((resolve, reject) -> {
				binaryLoader.onLoaded = resolve;
				binaryLoader.onError = reject;
				binaryLoader.load(true);
			});

			_transcoderPending = js.lib.Promise.all([jsContent, binaryContent]).then((arr) -> {
				final transcoder = arr[0].toString();
				final wasm = arr[1];
				final fn = basisWorker();
				final transcoderFormat = Type.getClassFields(Ktx2.TranscoderFormat).map(f -> '"$f": ${Reflect.field(Ktx2.TranscoderFormat, f)},\n').reduce((acc, curr) -> '$acc\t$curr', '{\n') + '}';
				final basisFormat = Type.allEnums(Ktx2.BasisFormat).reduce((acc, curr) -> '$acc\t"${curr.getName()}": ${curr.getIndex()},\n', '{\n') + '}';
				final engineFormat = Type.getClassFields(Ktx2.EngineFormat).map(f -> '"$f": ${Reflect.field(Ktx2.EngineFormat, f)},\n').reduce((acc, curr) -> '$acc\t$curr', '{\n') + '}';
				final engineType = Type.getClassFields(Ktx2.EngineType).map(f -> '"$f": ${Reflect.field(Ktx2.EngineType, f)},\n').reduce((acc, curr) -> '$acc\t$curr', '{\n') + '}';
				var body = [
					'/* constants */',
					'let _EngineFormat = $engineFormat',
					'let _EngineType = $engineType',
					'let _TranscoderFormat = $transcoderFormat',
					'let _BasisFormat = $basisFormat',
					'/* basis_transcoder.js */',
					transcoder,
					'/* worker */',
					fn.substring(fn.indexOf('{') + 1, fn.lastIndexOf('}'))
				].join('\n');

				_workerSourceURL = js.html.URL.createObjectURL(new js.html.Blob([body]));
				_transcoderBinary = wasm;
			});
		}

		return _transcoderPending;
	}

	static function getWorker() {
		return initTranscoder().then((val) -> {
			if (_workerPool.length < workerLimit) {
				final worker = new js.html.Worker(_workerSourceURL);
				final workerTask:Ktx2.WorkerTask = {
					worker: worker,
					callbacks: new haxe.ds.IntMap(),
					taskCosts: new haxe.ds.IntMap(),
					taskLoad: 0,
				}

				worker.postMessage({
					type: 'init',
					config: _workerConfig,
					transcoderBinary: _transcoderBinary,
				});

				worker.onmessage = (e) -> {
					var message = e.data;
					switch (message.type) {
						case 'transcode':
							workerTask.callbacks.get(message.id).resolve(message);
						case 'error':
							workerTask.callbacks.get(message.id).reject(message);
						default:
							throw 'BasisTextureLoader: Unexpected message, "' + message.type + '"';
					}
				}

				_workerPool.push(workerTask);
			} else {
				_workerPool.sort(function(a, b) {
					return a.taskLoad > b.taskLoad ? -1 : 1;
				});
			}

			return _workerPool[_workerPool.length - 1];
		});
	}

	static function basisWorker() {
		return "function () {
		let config;
		let transcoderPending;
		let BasisModule;
	
		const EngineFormat = _EngineFormat;
		const EngineType = _EngineType;
		const TranscoderFormat = _TranscoderFormat;
		const BasisFormat = _BasisFormat;
	
		self.addEventListener( 'message', function ( e ) {
			const message = e.data;
			switch ( message.type ) {
				case 'init':
					console.log(` message.config:${ JSON.stringify(message.config)}`);
					config = message.config;
					init( message.transcoderBinary );
					break;
				case 'transcode':
					transcoderPending.then( () => {
						try {
							const { faces, buffers, width, height, hasAlpha, format, type, dfdFlags } = transcode( message.buffer );
							self.postMessage( { type: 'transcode', id: message.id, data: { faces, width, height, hasAlpha, format, type, dfdFlags } }, buffers );
						} catch ( error ) {
							console.error( error );
							self.postMessage( { type: 'error', id: message.id, error: error.message } );
						}
					} );
					break;
			}
		} );
	
		function init( wasmBinary ) {
			transcoderPending = new Promise( ( resolve ) => {
				BasisModule = { wasmBinary, onRuntimeInitialized: resolve };
				BASIS( BasisModule ); // eslint-disable-line no-undef
			} ).then( () => {
				BasisModule.initializeBasis();
				console.log(`BasisModule.KTX2File:${BasisModule.KTX2File}`);
				if ( BasisModule.KTX2File === undefined ) {
					console.warn( 'KTX2Loader: Please update Basis Universal transcoder.' );
				}
			} );
		}
	
		function transcode( buffer ) {
			const ktx2File = new BasisModule.KTX2File( new Uint8Array( buffer ) );
			function cleanup() {
				ktx2File.close();
				ktx2File.delete();
			}
	
			if ( ! ktx2File.isValid() ) {
				cleanup();
				throw new Error( 'KTX2Loader:	Invalid or unsupported .ktx2 file' );
			}
	
			let basisFormat;
			if ( ktx2File.isUASTC() ) {
				basisFormat = BasisFormat.UASTC;
			} else if ( ktx2File.isETC1S() ) {
				basisFormat = BasisFormat.ETC1S;
			} else if ( ktx2File.isHDR() ) {
				basisFormat = BasisFormat.UASTC_HDR;
			} else {
				throw new Error( 'KTX2Loader: Unknown Basis encoding' );
			}
			console.log(`ktx2File.isUASTC():${ktx2File.isETC1S()}`);
			const width = ktx2File.getWidth();
			const height = ktx2File.getHeight();
			const layerCount = ktx2File.getLayers() || 1;
			const levelCount = ktx2File.getLevels();
			const faceCount = ktx2File.getFaces();
			const hasAlpha = ktx2File.getHasAlpha();
			const dfdFlags = ktx2File.getDFDFlags();
			const { transcoderFormat, engineFormat, engineType } = getTranscoderFormat( basisFormat, width, height, hasAlpha );
			if ( ! width || ! height || ! levelCount ) {
				cleanup();
				throw new Error( `KTX2Loader:	Invalid texture ktx2File:${JSON.stringify(ktx2File)} w:${width} h: ${height} levelCount:${levelCount}` );
			}
	
			if ( ! ktx2File.startTranscoding() ) {
				cleanup();
				throw new Error( 'KTX2Loader: .startTranscoding failed' );
			}
	
			const faces = [];
			const buffers = [];
	
			for ( let face = 0; face < faceCount; face ++ ) {
				const mipmaps = [];
				for ( let mip = 0; mip < levelCount; mip ++ ) {
					const layerMips = [];
					let mipWidth, mipHeight;
					for ( let layer = 0; layer < layerCount; layer ++ ) {
						const levelInfo = ktx2File.getImageLevelInfo( mip, layer, face );
						if ( face === 0 && mip === 0 && layer === 0 && ( levelInfo.origWidth % 4 !== 0 || levelInfo.origHeight % 4 !== 0 ) ) {
							console.warn( 'KTX2Loader: ETC1S and UASTC textures should use multiple-of-four dimensions.' );
						}
	
						if ( levelCount > 1 ) {
							mipWidth = levelInfo.origWidth;
							mipHeight = levelInfo.origHeight;
						} else {
							// Handles non-multiple-of-four dimensions in textures without mipmaps. Textures with
							// mipmaps must use multiple-of-four dimensions, for some texture formats and APIs.
							// See mrdoob/three.js#25908.
							mipWidth = levelInfo.width;
							mipHeight = levelInfo.height;
						}
	
						let dst = new Uint8Array( ktx2File.getImageTranscodedSizeInBytes( mip, layer, 0, transcoderFormat ) );
						const status = ktx2File.transcodeImage( dst, mip, layer, face, transcoderFormat, 0, - 1, - 1 );
	
						if ( engineType === EngineType.HalfFloatType ) {
							dst = new Uint16Array( dst.buffer, dst.byteOffset, dst.byteLength / Uint16Array.BYTES_PER_ELEMENT );
						}
	
						if ( ! status ) {
							cleanup();
							throw new Error( 'KTX2Loader: .transcodeImage failed.' );
						}
						layerMips.push( dst );
					}
					const mipData = concat( layerMips );
					mipmaps.push( { data: mipData, width: mipWidth, height: mipHeight } );
					buffers.push( mipData.buffer );
				}
				faces.push( { mipmaps, width, height, format: engineFormat, type: engineType } );
			}
			cleanup();
			return { faces, buffers, width, height, hasAlpha, dfdFlags, format: engineFormat, type: engineType };
		}
		//
	
		// Optimal choice of a transcoder target format depends on the Basis format (ETC1S, UASTC, or
		// UASTC HDR), device capabilities, and texture dimensions. The list below ranks the formats
		// separately for each format. Currently, priority is assigned based on:
		//
		//   high quality > low quality > uncompressed
		//
		// Prioritization may be revisited, or exposed for configuration, in the future.
		//
		// Reference: https://github.com/KhronosGroup/3D-Formats-Guidelines/blob/main/KTXDeveloperGuide.md
		const FORMAT_OPTIONS = [
			{
				if: 'astcSupported',
				basisFormat: [ BasisFormat.UASTC ],
				transcoderFormat: [ TranscoderFormat.ASTC_4x4, TranscoderFormat.ASTC_4x4 ],
				engineFormat: [ EngineFormat.RGBA_ASTC_4x4_Format, EngineFormat.RGBA_ASTC_4x4_Format ],
				engineType: [ EngineType.UnsignedByteType ],
				priorityETC1S: Infinity,
				priorityUASTC: 1,
				needsPowerOfTwo: false,
			},
			{
				if: 'bptcSupported',
				basisFormat: [ BasisFormat.ETC1S, BasisFormat.UASTC ],
				transcoderFormat: [ TranscoderFormat.BC7_M5, TranscoderFormat.BC7_M5 ],
				engineFormat: [ EngineFormat.RGBA_BPTC_Format, EngineFormat.RGBA_BPTC_Format ],
				engineType: [ EngineType.UnsignedByteType ],
				priorityETC1S: 3,
				priorityUASTC: 2,
				needsPowerOfTwo: false,
			},
			{
				if: 'dxtSupported',
				basisFormat: [ BasisFormat.ETC1S, BasisFormat.UASTC ],
				transcoderFormat: [ TranscoderFormat.BC1, TranscoderFormat.BC3 ],
				engineFormat: [ EngineFormat.RGBA_S3TC_DXT1_Format, EngineFormat.RGBA_S3TC_DXT5_Format ],
				engineType: [ EngineType.UnsignedByteType ],
				priorityETC1S: 4,
				priorityUASTC: 5,
				needsPowerOfTwo: false,
			},
			{
				if: 'etc2Supported',
				basisFormat: [ BasisFormat.ETC1S, BasisFormat.UASTC ],
				transcoderFormat: [ TranscoderFormat.ETC1, TranscoderFormat.ETC2 ],
				engineFormat: [ EngineFormat.RGB_ETC2_Format, EngineFormat.RGBA_ETC2_EAC_Format ],
				engineType: [ EngineType.UnsignedByteType ],
				priorityETC1S: 1,
				priorityUASTC: 3,
				needsPowerOfTwo: false,
			},
			{
				if: 'etc1Supported',
				basisFormat: [ BasisFormat.ETC1S, BasisFormat.UASTC ],
				transcoderFormat: [ TranscoderFormat.ETC1 ],
				engineFormat: [ EngineFormat.RGB_ETC1_Format ],
				engineType: [ EngineType.UnsignedByteType ],
				priorityETC1S: 2,
				priorityUASTC: 4,
				needsPowerOfTwo: false,
			},
			{
				if: 'pvrtcSupported',
				basisFormat: [ BasisFormat.ETC1S, BasisFormat.UASTC ],
				transcoderFormat: [ TranscoderFormat.PVRTC1_4_RGB, TranscoderFormat.PVRTC1_4_RGBA ],
				engineFormat: [ EngineFormat.RGB_PVRTC_4BPPV1_Format, EngineFormat.RGBA_PVRTC_4BPPV1_Format ],
				engineType: [ EngineType.UnsignedByteType ],
				priorityETC1S: 5,
				priorityUASTC: 6,
				needsPowerOfTwo: true,
			},
			{
				if: 'bptcSupported',
				basisFormat: [ BasisFormat.UASTC_HDR ],
				transcoderFormat: [ TranscoderFormat.BC6H ],
				engineFormat: [ EngineFormat.RGB_BPTC_UNSIGNED_Format ],
				engineType: [ EngineType.HalfFloatType ],
				priorityHDR: 1,
				needsPowerOfTwo: false,
			},
	
			// Uncompressed fallbacks.
	
			{
				basisFormat: [ BasisFormat.ETC1S, BasisFormat.UASTC ],
				transcoderFormat: [ TranscoderFormat.RGBA32, TranscoderFormat.RGBA32 ],
				engineFormat: [ EngineFormat.RGBAFormat, EngineFormat.RGBAFormat ],
				engineType: [ EngineType.UnsignedByteType, EngineType.UnsignedByteType ],
				priorityETC1S: 100,
				priorityUASTC: 100,
				needsPowerOfTwo: false,
			},
			{
				basisFormat: [ BasisFormat.UASTC_HDR ],
				transcoderFormat: [ TranscoderFormat.RGBA_HALF ],
				engineFormat: [ EngineFormat.RGBAFormat ],
				engineType: [ EngineType.HalfFloatType ],
				priorityHDR: 100,
				needsPowerOfTwo: false,
			}
		];
	
		const OPTIONS = {
			// TODO: For ETC1S we intentionally sort by _UASTC_ priority, preserving
			// a historical accident shown to avoid performance pitfalls for Linux with
			// Firefox & AMD GPU (RadeonSI). Further work needed.
			// See https://github.com/mrdoob/three.js/pull/29730.
			[ BasisFormat.ETC1S ]: FORMAT_OPTIONS
				.filter( ( opt ) => opt.basisFormat.includes( BasisFormat.ETC1S ) )
				.sort( ( a, b ) => a.priorityUASTC - b.priorityUASTC ),
	
			[ BasisFormat.UASTC ]: FORMAT_OPTIONS
				.filter( ( opt ) => opt.basisFormat.includes( BasisFormat.UASTC ) )
				.sort( ( a, b ) => a.priorityUASTC - b.priorityUASTC ),
	
			[ BasisFormat.UASTC_HDR ]: FORMAT_OPTIONS
				.filter( ( opt ) => opt.basisFormat.includes( BasisFormat.UASTC_HDR ) )
				.sort( ( a, b ) => a.priorityHDR - b.priorityHDR ),
		};
	
		function getTranscoderFormat( basisFormat, width, height, hasAlpha ) {
			const options = OPTIONS[ basisFormat ];
			console.log(`options:${options}`);
			for ( let i = 0; i < options.length; i ++ ) {
				const opt = options[ i ];
				console.log(`config:${JSON.stringify(config)}`);
				console.log(`Opt: ${JSON.stringify(opt)}`);
				if ( opt.if && ! config[ opt.if ] ) continue;
				if ( ! opt.basisFormat.includes( basisFormat ) ) continue;
				if ( hasAlpha && opt.transcoderFormat.length < 2 ) continue;
				if ( opt.needsPowerOfTwo && ! ( isPowerOfTwo( width ) && isPowerOfTwo( height ) ) ) continue;
				console.log(`hasAlpha:${hasAlpha}`);
				console.log(`opt.engineFormat:${opt.engineFormat}`);
				const transcoderFormat = opt.transcoderFormat[ hasAlpha ? 1 : 0 ];
				const engineFormat = opt.engineFormat[ hasAlpha ? 1 : 0 ];
				const engineType = opt.engineType[ 0 ];
				console.log(`transcoderFormat: ${JSON.stringify(transcoderFormat)}`);
	
				return { transcoderFormat, engineFormat, engineType };
			}
			throw new Error( 'KTX2Loader: Failed to identify transcoding target.' );
		}
	
		function isPowerOfTwo( value ) {
			if ( value <= 2 ) return true;
			return ( value & ( value - 1 ) ) === 0 && value !== 0;
		}
	
		/** Concatenates N byte arrays. */
		function concat( arrays ) {
			if ( arrays.length === 1 ) return arrays[ 0 ];
			let totalByteLength = 0;
	
			for ( let i = 0; i < arrays.length; i ++ ) {
				const array = arrays[ i ];
				totalByteLength += array.byteLength;
			}
	
			const result = new Uint8Array( totalByteLength );
			let byteOffset = 0;
	
			for ( let i = 0; i < arrays.length; i ++ ) {
				const array = arrays[ i ];
				result.set( array, byteOffset );
				byteOffset += array.byteLength;
			}
	
			return result;
		}
	}";
	}
}

#end

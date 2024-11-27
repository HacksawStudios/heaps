package h3d.shader;

class Base2d extends hxsl.Shader {

    static var SRC = {

        @input var input : {
            var position : Vec2;
            var uv : Vec2;
            var color : Vec4;
        };

        var output : {
            var position : Vec4;
            var color : Vec4;
        };

        @global var time : Float;
        @param var zValue : Float;
        @param var texture : Sampler2D;

        var spritePosition : Vec4;
        var absolutePosition : Vec4;
        var pixelColor : Vec4;
        var textureColor : Vec4;
        @var var calculatedUV : Vec2;

        @const var isRelative : Bool;
        @param var color : Vec4;
        @param var absoluteMatrixA : Vec3;
        @param var absoluteMatrixB : Vec3;
        @param var filterMatrixA : Vec3;
        @param var filterMatrixB : Vec3;
        @const var hasUVPos : Bool;
        @param var uvPos : Vec4;

        @const var killAlpha : Bool;
        @const var pixelAlign : Bool;
        @param var halfPixelInverse : Vec2;
        @param var viewportA : Vec3;
        @param var viewportB : Vec3;

        var outputPosition : Vec4;

        function __init__() {
            spritePosition = vec4(input.position, zValue, 1);

            // Calculate absolute position
            if (isRelative) {
                var tempVec = vec3(spritePosition.xy, 1);
                absolutePosition = vec4(
                    tempVec.dot(absoluteMatrixA),
                    tempVec.dot(absoluteMatrixB),
                    spritePosition.z,
                    spritePosition.w
                );
            } else {
                absolutePosition = spritePosition;
            }

            // Calculate UV coordinates
            if (hasUVPos) {
                calculatedUV = input.uv * uvPos.zw + uvPos.xy;
            } else {
                calculatedUV = input.uv;
            }

            // Calculate color
            if (isRelative) {
                pixelColor = color * input.color;
            } else {
                pixelColor = input.color;
            }

            // Sample texture color and multiply
            textureColor = texture.get(calculatedUV);
            pixelColor *= textureColor;
        }

        function vertex() {
            // Transform absolute position to render texture coordinates
            var tempVec = vec3(absolutePosition.xy, 1);
            var filteredPos = vec3(
                tempVec.dot(filterMatrixA),
                tempVec.dot(filterMatrixB),
                1
            );

            // Transform to viewport space
            outputPosition = vec4(
                filteredPos.dot(viewportA),
                filteredPos.dot(viewportB),
                absolutePosition.z,
                absolutePosition.w
            );

            // Pixel alignment correction
            if (pixelAlign) {
                outputPosition.xy -= halfPixelInverse;
            }

            output.position = outputPosition;
        }

        function fragment() {
            // Discard if alpha is too low
            if (killAlpha && pixelColor.a < 0.001) {
                discard;
            }

            output.color = pixelColor;
        }
    };
}
using SharedMic.Agent.Protocol;
using SharedMic.Agent.Security;
using Xunit;

namespace SharedMic.Agent.Tests;

public class PairingAndAuthTests
{
    [Fact]
    public void TokenIs256Bits()
    {
        Assert.Equal(32, PairingToken.Generate().Length);
        Assert.Equal(ProtocolConstants.TokenBytes, PairingToken.Generate().Length);
    }

    [Fact]
    public void TokensAreNotRepeated()
    {
        var tokens = new HashSet<string>();
        for (var i = 0; i < 64; i++)
        {
            Assert.True(tokens.Add(Convert.ToHexString(PairingToken.Generate())));
        }
    }

    [Fact]
    public void EncodesTheWorkedExampleFromTheContract()
    {
        var token = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();

        Assert.Equal(
            "AAAQEAYE-AUDAOCAJ-BIFQYDIO-B4IBCEQT-CQKRMFYY-DENBWHA5-DYPQ",
            PairingToken.Encode(token));
    }

    [Fact]
    public void PairingStringIsAlwaysFiftyEightCharactersInGroupsOfEight()
    {
        for (var i = 0; i < 20; i++)
        {
            var text = PairingToken.Encode(PairingToken.Generate());

            Assert.Equal(58, text.Length);
            var groups = text.Split('-');
            Assert.Equal(7, groups.Length);
            Assert.All(groups.Take(6), group => Assert.Equal(8, group.Length));
            Assert.Equal(4, groups[6].Length);
            Assert.DoesNotContain('=', text);
            Assert.Equal(text.ToUpperInvariant(), text);
        }
    }

    [Fact]
    public void EncodeDecodeIsTheIdentity()
    {
        for (var i = 0; i < 20; i++)
        {
            var token = PairingToken.Generate();
            Assert.Equal(token, PairingToken.Decode(PairingToken.Encode(token)));
        }
    }

    [Fact]
    public void DecodeToleratesHumanTranscription()
    {
        var token = PairingToken.Generate();
        var text = PairingToken.Encode(token);

        Assert.Equal(token, PairingToken.Decode(text.ToLowerInvariant()));
        Assert.Equal(token, PairingToken.Decode(text.Replace("-", " ")));
        Assert.Equal(token, PairingToken.Decode(text.Replace("-", "")));
        Assert.Equal(token, PairingToken.Decode("  " + text.Replace("-", "\t") + "\r\n"));
    }

    [Fact]
    public void DecodeRejectsGarbage()
    {
        Assert.Throws<FormatException>(() => PairingToken.Decode("hello, world!"));
        Assert.Throws<FormatException>(() => PairingToken.Decode(""));
    }

    [Fact]
    public void DecodeRejectsWrongLength()
    {
        var token = PairingToken.Generate();
        var text = PairingToken.Encode(token);

        Assert.Throws<FormatException>(() => PairingToken.Decode(text.Substring(0, 20)));
        Assert.Throws<FormatException>(() => PairingToken.Decode(text + "-AAAAAAAA"));
    }

    [Fact]
    public void DecodeDoesNotMapConfusableCharacters()
    {
        var token = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();
        var text = PairingToken.Encode(token);

        // '0' and '1' are outside the RFC 4648 alphabet, so they are deleted,
        // not corrected. Deleting a character shortens the decode below 32
        // bytes, which the length check must reject.
        Assert.Throws<FormatException>(() => PairingToken.Decode(text.Replace("O", "0")));
    }

    [Fact]
    public void NonceIs256BitsAndFreshEveryTime()
    {
        var nonces = new HashSet<string>();
        for (var i = 0; i < 64; i++)
        {
            var nonce = AuthProof.GenerateNonce();
            Assert.Equal(ProtocolConstants.NonceBytes, nonce.Length);
            Assert.True(nonces.Add(Convert.ToHexString(nonce)));
        }
    }

    [Fact]
    public void ProofMatchesTheReferenceHmac()
    {
        Assert.Equal(
            "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a",
            AuthProof.Compute(new byte[32], new byte[32]));

        var token = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();
        var nonce = Enumerable.Range(32, 32).Select(i => (byte)i).ToArray();

        Assert.Equal(
            "62215de7bddcea7e2c4047ff6bb94f8d18262fc8b3f3648134bb7d44158ff84d",
            AuthProof.Compute(token, nonce));
    }

    [Fact]
    public void ProofIsLowercaseHexOfSixtyFourCharacters()
    {
        var proof = AuthProof.Compute(PairingToken.Generate(), AuthProof.GenerateNonce());

        Assert.Equal(64, proof.Length);
        Assert.Equal(proof.ToLowerInvariant(), proof);
    }

    [Fact]
    public void VerifyAcceptsTheMatchingProof()
    {
        var token = PairingToken.Generate();
        var nonce = AuthProof.GenerateNonce();

        Assert.True(AuthProof.Verify(token, nonce, AuthProof.Compute(token, nonce)));
    }

    [Fact]
    public void VerifyRejectsAWrongTokenAWrongNonceAndMalformedProofs()
    {
        var token = PairingToken.Generate();
        var nonce = AuthProof.GenerateNonce();
        var proof = AuthProof.Compute(token, nonce);

        Assert.False(AuthProof.Verify(PairingToken.Generate(), nonce, proof));
        Assert.False(AuthProof.Verify(token, AuthProof.GenerateNonce(), proof));
        Assert.False(AuthProof.Verify(token, nonce, null));
        Assert.False(AuthProof.Verify(token, nonce, ""));
        Assert.False(AuthProof.Verify(token, nonce, "not hex at all"));
        Assert.False(AuthProof.Verify(token, nonce, proof.Substring(0, 62)));
        Assert.False(AuthProof.Verify(token, nonce, proof + "00"));
    }

    [Fact]
    public void ProofIsComputedOverRawNonceBytesNotTheHexString()
    {
        var token = PairingToken.Generate();
        var nonce = AuthProof.GenerateNonce();
        var hexBytes = System.Text.Encoding.ASCII.GetBytes(Convert.ToHexString(nonce).ToLowerInvariant());

        Assert.NotEqual(AuthProof.Compute(token, hexBytes), AuthProof.Compute(token, nonce));
    }
}

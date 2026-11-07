// Compare unmodified and analyst-overridden flow in an ephemeral Ghidra database.
// Does not patch program bytes or execute the inspected target.
// @category Mangekyou.StaticResearch
import ghidra.app.script.GhidraScript;
import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.FlowOverride;
import ghidra.program.model.pcode.JumpTable;
import com.google.gson.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;

public class BoundTailProbe extends GhidraScript {
    private String digest(byte[] b) throws Exception {
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(b));
    }
    private byte[] bytes(Address a, int size) throws Exception {
        byte[] result=new byte[size];
        if (currentProgram.getMemory().getBytes(a,result)!=size) throw new Exception("short memory read");
        return result;
    }
    private JsonObject decompile(Function f) throws Exception {
        JsonObject r=new JsonObject(); DecompInterface api=new DecompInterface();
        try {
            if (!api.openProgram(currentProgram)) throw new Exception("decompiler open failed");
            DecompileResults d=api.decompileFunction(f,30,monitor);
            r.addProperty("status",d.decompileCompleted() && d.getDecompiledFunction()!=null ? "verified":"unsupported");
            r.addProperty("error",d.getErrorMessage());
            if (d.getDecompiledFunction()!=null) r.addProperty("pseudocode",d.getDecompiledFunction().getC());
            r.addProperty("body_min",f.getBody().getMinAddress().toString());
            r.addProperty("body_max",f.getBody().getMaxAddress().toString());
            r.addProperty("body_bytes",f.getBody().getNumAddresses());
        } finally { api.dispose(); }
        return r;
    }
    @Override public void run() throws Exception {
        String[] args=getScriptArgs();
        if (args.length!=2) throw new Exception("Expected plan path and private output path");
        Path planPath=Path.of(args[0]);Path output=Path.of(args[1]);
        JsonObject plan=JsonParser.parseString(Files.readString(planPath)).getAsJsonObject();
        String importedSHA=currentProgram.getExecutableSHA256();
        if (importedSHA==null || !importedSHA.equalsIgnoreCase(plan.get("source_sha256").getAsString()))
            throw new Exception("imported program SHA-256 does not match plan");
        JsonArray specs=plan.getAsJsonArray("functions");
        if (specs.size()==0 || specs.size()>16) throw new Exception("function count limit");
        JsonObject report=new JsonObject();report.addProperty("status","verified");
        report.addProperty("authority","analyst-inference");
        report.addProperty("target_executed",false);report.addProperty("program_bytes_patched",false);
        report.addProperty("source_sha256",plan.get("source_sha256").getAsString());
        report.addProperty("scope","Ephemeral database flow override experiment; not original execution or unmodified REA Evidence");
        JsonArray results=new JsonArray();int total=0;
        for (JsonElement element:specs) {
            JsonObject spec=element.getAsJsonObject();JsonObject item=new JsonObject();
            item.addProperty("name",spec.get("name").getAsString());
            try {
                Address start=toAddr(spec.get("start").getAsString());
                Address end=toAddr(spec.get("end_exclusive").getAsString());
                long length=end.subtract(start);total+=length;
                if (length<=0 || length>8192 || total>32768) throw new Exception("byte range limit");
                AddressSet allowed=new AddressSet(start,end.subtract(1));
                byte[] before=bytes(start,(int)length);
                item.addProperty("source_memory_sha256",digest(before));
                // Function spans can contain literal pools and switch tables.
                // Preserve those data definitions; never force a linear decode.
                if (getInstructionAt(start)==null)
                    new DisassembleCommand(start,allowed,true).applyTo(currentProgram,monitor);
                Function function=getFunctionAt(start);
                if (function==null) function=createFunction(start,"probe_"+spec.get("name").getAsString());
                if (function==null) throw new Exception("could not create function");
                item.add("baseline",decompile(function));
                AddressSet expanded=new AddressSet(function.getBody());
                JsonArray mutations=new JsonArray();
                for (JsonElement r:spec.getAsJsonArray("cleanup_returns")) {
                    Address address=toAddr(r.getAsString());
                    if (!allowed.contains(address)) throw new Exception("override outside range");
                    Instruction instruction=getInstructionAt(address);
                    if (instruction==null || !instruction.getMnemonicString().equalsIgnoreCase("RET"))
                        throw new Exception("override is not a decoded RET");
                    JsonObject mutation=new JsonObject();mutation.addProperty("address",address.toString());
                    mutation.addProperty("before",instruction.getFlowOverride().toString());
                    instruction.setFlowOverride(FlowOverride.BRANCH);
                    mutation.addProperty("after",instruction.getFlowOverride().toString());
                    if (spec.has("return_targets")) {
                        Address target=toAddr(spec.getAsJsonObject("return_targets").get(r.getAsString()).getAsString());
                        if (!allowed.contains(target)) throw new Exception("return target outside function range");
                        boolean foundPush=false;
                        long begin=Math.max(start.getOffset(),address.getOffset()-96);
                        for (long v=begin;v<address.getOffset();v++) {
                            Instruction candidate=getInstructionAt(toAddr(v));
                            if (candidate==null) continue;
                            byte[] encoded=candidate.getBytes();
                            if (encoded.length!=5 || (encoded[0]&255)!=0x68) continue;
                            long immediate=0;
                            for (int j=1;j<5;j++) immediate|=((long)encoded[j]&255)<<(8*(j-1));
                            if (immediate==target.getOffset()) {
                                foundPush=true;mutation.addProperty("continuation_push",candidate.getAddress().toString());break;
                            }
                        }
                        if (!foundPush) throw new Exception("no decoded PUSH of continuation before cleanup RET");
                        new DisassembleCommand(target,allowed,true).applyTo(currentProgram,monitor);
                        Address cursor=target;
                        while (cursor.compareTo(end)<0) {
                            Instruction tail=getInstructionAt(cursor);
                            if (tail==null || tail.getMaxAddress().compareTo(end)>=0)
                                throw new Exception("continuation tail is not fully decoded at "+cursor);
                            expanded.add(tail.getMinAddress(),tail.getMaxAddress());
                            cursor=tail.getMaxAddress().add(1);
                        }
                        new JumpTable(address,new ArrayList<Address>(List.of(target)),true,0).writeOverride(function);
                        mutation.addProperty("analyst_single_target",target.toString());
                        mutation.addProperty("target_model_status","inferred");
                    }
                    mutations.add(mutation);
                }
                function.setBody(expanded);item.add("metadata_overrides",mutations);
                JsonObject variant=decompile(function);item.add("variant",variant);
                byte[] after=bytes(start,(int)length);
                item.addProperty("memory_unchanged",Arrays.equals(before,after));
                item.addProperty("memory_sha256_after",digest(after));
                boolean okay=Arrays.equals(before,after) &&
                    item.getAsJsonObject("baseline").get("status").getAsString().equals("verified") &&
                    variant.get("status").getAsString().equals("verified");
                item.addProperty("status",okay?"verified":"unsupported");
                if (!okay) report.addProperty("status","unsupported");
            } catch (Exception e) {
                item.addProperty("status","unsupported");item.addProperty("error",e.toString());
                report.addProperty("status","unsupported");
            }
            results.add(item);
        }
        report.add("functions",results);
        Files.writeString(output,new GsonBuilder().setPrettyPrinting().create().toJson(report)+"\n",StandardCharsets.UTF_8,
            StandardOpenOption.CREATE_NEW,StandardOpenOption.WRITE);
        println("Mangekyou static database comparison finished: "+results.size()+" functions");
    }
}
